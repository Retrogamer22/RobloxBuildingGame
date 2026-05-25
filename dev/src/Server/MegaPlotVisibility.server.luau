--[[
	MegaPlotVisibility (Server)
	Controls visibility of MegaPlotRoom based on server type and mode
	
	- Public servers: MegaPlotRoom is HIDDEN (moved to ServerStorage)
	- Private servers (Individual mode): MegaPlotRoom is HIDDEN, individual BuildAreas visible
	- Private servers (MegaPlot mode): MegaPlotRoom is VISIBLE, individual BuildAreas HIDDEN
	
	Also handles terrain generation for the MegaPlot
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

-- GrassSpreadManager reference (loaded lazily)
local GrassSpreadManager = nil
local function getGrassSpreadManager()
	if GrassSpreadManager then return GrassSpreadManager end
	pcall(function()
		local Modules = ServerScriptService:WaitForChild("Modules", 5)
		if Modules then
			local grassModule = Modules:FindFirstChild("GrassSpreadManager")
			if grassModule then
				GrassSpreadManager = require(grassModule)
			end
		end
	end)
	return GrassSpreadManager
end

-- Configuration
local MEGAPLOT_ROOM_NAME = "MegaPlotRoom"
local MEGAPLOT_BASEPLATE_NAME = "MegaPlot"  -- The baseplate inside MegaPlotRoom

-- Storage for hidden objects
local hiddenStorage = ServerStorage:FindFirstChild("HiddenObjects")
if not hiddenStorage then
	hiddenStorage = Instance.new("Folder")
	hiddenStorage.Name = "HiddenObjects"
	hiddenStorage.Parent = ServerStorage
end

-- Subfolder for individual plots
local hiddenPlots = hiddenStorage:FindFirstChild("IndividualPlots")
if not hiddenPlots then
	hiddenPlots = Instance.new("Folder")
	hiddenPlots.Name = "IndividualPlots"
	hiddenPlots.Parent = hiddenStorage
end

-- References (set during initialization)
local megaPlotRoom = nil
local individualBuildAreas = {}  -- {BuildArea = originalParent}

-- Terrain ready tracking
local megaPlotTerrainReady = false
local terrainReadyValue = nil  -- BoolValue in ReplicatedStorage
local terrainGenerationInProgress = false  -- Prevent duplicate generation

-- Remote to tell clients to show loading screen
local showLoadingScreenRemote = nil

-- Player protection tracking (keep anchored/protected until title screen dismissed)
local playerProtection = {} -- [player] = {hrp, forceField, timeout}

-- ============================================
-- FIND OBJECTS
-- ============================================

local function findMegaPlotRoom()
	-- Check workspace first
	local inWorkspace = Workspace:FindFirstChild(MEGAPLOT_ROOM_NAME)
	if inWorkspace then
		return inWorkspace
	end
	
	-- Check descendants of workspace
	for _, child in ipairs(Workspace:GetDescendants()) do
		if child.Name == MEGAPLOT_ROOM_NAME then
			return child
		end
	end
	
	-- Check if already hidden in ServerStorage
	local inStorage = hiddenStorage:FindFirstChild(MEGAPLOT_ROOM_NAME)
	if inStorage then
		return inStorage
	end
	
	return nil
end

local function findIndividualBuildAreas()
	local areas = {}
	
	-- Find all BuildArea models numbered 1-9
	for i = 1, 9 do
		local name = "BuildArea" .. i
		
		-- Check workspace descendants
		for _, obj in ipairs(Workspace:GetDescendants()) do
			if obj.Name == name then
				areas[name] = {
					buildArea = obj,
					originalParent = obj.Parent
				}
				break
			end
		end
		
		-- Also check hidden storage (might already be hidden)
		if not areas[name] then
			local hidden = hiddenPlots:FindFirstChild(name)
			if hidden then
				areas[name] = {
					buildArea = hidden,
					originalParent = Workspace  -- Default to workspace if unknown
				}
			end
		end
	end
	
	return areas
end

-- ============================================
-- VISIBILITY CONTROL
-- ============================================

local function hideMegaPlotRoom()
	if not megaPlotRoom then return end
	
	if megaPlotRoom.Parent ~= hiddenStorage then
		print("[MegaPlotVisibility] Hiding MegaPlotRoom")
		megaPlotRoom.Parent = hiddenStorage
	end
end

local function showMegaPlotRoom()
	if not megaPlotRoom then
		warn("[MegaPlotVisibility] MegaPlotRoom not found!")
		return false
	end
	
	if megaPlotRoom.Parent ~= Workspace then
		print("[MegaPlotVisibility] Showing MegaPlotRoom")
		megaPlotRoom.Parent = Workspace
	end
	return true
end

local function hideIndividualBuildAreas()
	for name, data in pairs(individualBuildAreas) do
		local buildArea = data.buildArea
		if buildArea and buildArea.Parent ~= hiddenPlots then
			-- Store original parent before hiding
			if buildArea.Parent and buildArea.Parent ~= hiddenPlots then
				data.originalParent = buildArea.Parent
			end
			print("[MegaPlotVisibility] Hiding", name)
			buildArea.Parent = hiddenPlots
		end
	end
end

local function showIndividualBuildAreas()
	for name, data in pairs(individualBuildAreas) do
		local buildArea = data.buildArea
		if buildArea and buildArea.Parent == hiddenPlots then
			local targetParent = data.originalParent or Workspace
			print("[MegaPlotVisibility] Showing", name, "-> parent:", targetParent.Name)
			buildArea.Parent = targetParent
		end
	end
end

-- ============================================
-- PLAYER SPAWNING
-- ============================================

local function getMegaPlotSpawnPosition()
	if not megaPlotRoom then return nil end
	
	-- Find the MegaPlot baseplate
	local megaPlot = megaPlotRoom:FindFirstChild(MEGAPLOT_BASEPLATE_NAME)
	if not megaPlot then
		for _, child in ipairs(megaPlotRoom:GetDescendants()) do
			if child.Name == MEGAPLOT_BASEPLATE_NAME and child:IsA("BasePart") then
				megaPlot = child
				break
			end
		end
	end
	
	if not megaPlot or not megaPlot:IsA("BasePart") then
		return nil
	end
	
	-- Base position: center of baseplate
	local baseplateTopY = megaPlot.Position.Y + megaPlot.Size.Y / 2
	local centerX = megaPlot.Position.X
	local centerZ = megaPlot.Position.Z
	
	-- Raycast down from high up to find the actual terrain surface
	-- This prevents spawning inside natural terrain hills
	local rayOrigin = Vector3.new(centerX, baseplateTopY + 300, centerZ)
	local rayDirection = Vector3.new(0, -350, 0)
	
	local rayParams = RaycastParams.new()
	-- Only hit blocks in the build area, not the invisible baseplate
	local buildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
	if buildArea then
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		if blocksFolder and #blocksFolder:GetChildren() > 0 then
			rayParams.FilterType = Enum.RaycastFilterType.Include
			rayParams.FilterDescendantsInstances = {blocksFolder}
			
			local result = workspace:Raycast(rayOrigin, rayDirection, rayParams)
			if result then
				-- Spawn 5 studs above the highest terrain block at center
				return Vector3.new(centerX, result.Position.Y + 5, centerZ)
			end
		end
	end
	
	-- Fallback: no terrain blocks yet, use baseplate + 5
	return Vector3.new(centerX, baseplateTopY + 5, centerZ)
end

-- Release player protection (unanchor + remove ALL ForceFields)
local function releasePlayerProtection(player)
	playerProtection[player] = nil
	
	local character = player.Character
	if not character then return end
	
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp.Parent then
		hrp.Anchored = false
	end
	
	-- Remove ALL protection ForceFields (handles stacked protections)
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("ForceField") then
			child:Destroy()
		end
	end
	
	print("[MegaPlotVisibility] Released protection for", player.Name)
end

local function teleportPlayerToMegaPlot(player, keepProtection)
	local character = player.Character
	if not character then 
		warn("[MegaPlotVisibility] Teleport failed - no character for", player.Name)
		return false 
	end
	
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then 
		warn("[MegaPlotVisibility] Teleport failed - no HumanoidRootPart for", player.Name)
		return false 
	end
	
	local humanoid = character:FindFirstChild("Humanoid")
	
	local spawnPos = getMegaPlotSpawnPosition()
	if not spawnPos then
		warn("[MegaPlotVisibility] Could not get MegaPlot spawn position")
		return false
	end
	
	print("[MegaPlotVisibility] Teleporting", player.Name, "to MegaPlot at position:", spawnPos)
	
	-- Unseat player if seated
	if humanoid and humanoid.Sit then
		humanoid.Sit = false
		task.wait(0.1)
	end
	
	-- Add protection during teleport
	humanoidRootPart.Anchored = true
	local forceField = character:FindFirstChild("TeleportProtection")
	if not forceField then
		forceField = Instance.new("ForceField")
		forceField.Name = "TeleportProtection"
		forceField.Visible = false
		forceField.Parent = character
	end
	
	-- Use PivotTo for more reliable teleportation
	character:PivotTo(CFrame.new(spawnPos))
	
	print("[MegaPlotVisibility] After teleport, new position:", humanoidRootPart.Position)
	
	if keepProtection then
		-- Store protection refs - will be released when client signals ready
		playerProtection[player] = true
		-- Safety timeout: release after 10s no matter what (client should fire MegaPlotPlayerReady sooner)
		task.delay(10, function()
			if playerProtection[player] then
				print("[MegaPlotVisibility] Protection timeout for", player.Name, "- releasing")
				releasePlayerProtection(player)
			end
		end)
	else
		-- Normal teleport: unanchor after brief delay
		task.delay(0.3, function()
			if humanoidRootPart and humanoidRootPart.Parent then
				humanoidRootPart.Anchored = false
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
	
	return true
end

local function teleportAllPlayersToMegaPlot(keepProtection)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			teleportPlayerToMegaPlot(player, keepProtection)
		end)
	end
end

-- Teleport a player to their individual plot
local function teleportPlayerToIndividualPlot(player)
	local character = player.Character
	if not character then 
		warn("[MegaPlotVisibility] Cannot teleport to individual plot - no character for", player.Name)
		return false 
	end
	
	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then 
		warn("[MegaPlotVisibility] Cannot teleport to individual plot - no HumanoidRootPart for", player.Name)
		return false 
	end
	
	local humanoid = character:FindFirstChild("Humanoid")
	
	-- Find the player's assigned BuildArea by checking OwnerUserId attribute
	local targetBuildArea = nil
	for i = 1, 9 do
		local buildArea = Workspace:FindFirstChild("BuildArea" .. i)
		if buildArea and buildArea:GetAttribute("OwnerUserId") == player.UserId then
			targetBuildArea = buildArea
			break
		end
	end
	
	if not targetBuildArea then
		warn("[MegaPlotVisibility] No assigned BuildArea found for", player.Name)
		return false
	end
	
	-- Get spawn position from stored baseplate attributes
	local posX = targetBuildArea:GetAttribute("BasePlatePositionX")
	local posY = targetBuildArea:GetAttribute("BasePlatePositionY")
	local posZ = targetBuildArea:GetAttribute("BasePlatePositionZ")
	local sizeY = targetBuildArea:GetAttribute("BasePlateSizeY")
	
	if not (posX and posY and posZ and sizeY) then
		warn("[MegaPlotVisibility] BuildArea missing position attributes for", player.Name)
		return false
	end
	
	local plateTop = posY + sizeY / 2
	local spawnPos = Vector3.new(posX, plateTop + 5, posZ)
	
	print("[MegaPlotVisibility] Teleporting", player.Name, "to individual plot at position:", spawnPos)
	
	-- Unseat player if seated
	if humanoid and humanoid.Sit then
		humanoid.Sit = false
		task.wait(0.1)
	end
	
	-- Clear RespawnLocation so they spawn at individual plot on death
	player.RespawnLocation = nil
	
	-- Add protection during teleport
	humanoidRootPart.Anchored = true
	local forceField = character:FindFirstChild("TeleportProtection")
	if not forceField then
		forceField = Instance.new("ForceField")
		forceField.Name = "TeleportProtection"
		forceField.Visible = false
		forceField.Parent = character
	end
	
	-- Use PivotTo for more reliable teleportation
	character:PivotTo(CFrame.new(spawnPos))
	
	-- Wait a moment for terrain to register, then unanchor
	task.delay(0.3, function()
		if humanoidRootPart and humanoidRootPart.Parent then
			humanoidRootPart.Anchored = false
		end
		if forceField and forceField.Parent then
			task.delay(0.5, function()
				if forceField and forceField.Parent then
					forceField:Destroy()
				end
			end)
		end
	end)
	
	print("[MegaPlotVisibility] Teleported", player.Name, "to individual plot")
	return true
end

local function teleportAllPlayersToIndividualPlots()
	print("[MegaPlotVisibility] Teleporting all players to their individual plots...")
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			teleportPlayerToIndividualPlot(player)
		end)
	end
end

-- ============================================
-- BASEPLATE MANAGEMENT
-- ============================================

local function ensureBaseplateHidden()
	-- Find and hide the MegaPlot baseplate
	if not megaPlotRoom then return end
	
	local megaPlot = megaPlotRoom:FindFirstChild(MEGAPLOT_BASEPLATE_NAME)
	if not megaPlot then
		for _, child in ipairs(megaPlotRoom:GetDescendants()) do
			if child.Name == MEGAPLOT_BASEPLATE_NAME and child:IsA("BasePart") then
				megaPlot = child
				break
			end
		end
	end
	
	if megaPlot and megaPlot:IsA("BasePart") then
		print("[MegaPlotVisibility] Ensuring MegaPlot baseplate is hidden")
		megaPlot.Transparency = 1
		megaPlot.CanCollide = false
		megaPlot.CanQuery = false  -- Critical: prevents raycasts from hitting invisible baseplate
	end
end

-- ============================================
-- TERRAIN GENERATION FOR MEGAPLOT
-- (Must be defined BEFORE applyMode which uses it)
-- ============================================

local function getMegaPlotBuildArea()
	print("[MegaPlotVisibility] getMegaPlotBuildArea called")
	print("[MegaPlotVisibility] megaPlotRoom:", megaPlotRoom and megaPlotRoom.Name or "NIL")
	
	if not megaPlotRoom then 
		warn("[MegaPlotVisibility] megaPlotRoom is nil!")
		return nil 
	end
	
	-- Find or create the build area
	local buildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
	if buildArea then 
		print("[MegaPlotVisibility] Found existing MegaPlotBuildArea")
		return buildArea 
	end
	
	-- Find the MegaPlot baseplate
	local megaPlot = megaPlotRoom:FindFirstChild(MEGAPLOT_BASEPLATE_NAME)
	print("[MegaPlotVisibility] Direct FindFirstChild for MegaPlot:", megaPlot and megaPlot.Name or "NIL")
	
	if not megaPlot then
		print("[MegaPlotVisibility] Searching descendants...")
		for _, child in ipairs(megaPlotRoom:GetDescendants()) do
			if child.Name == MEGAPLOT_BASEPLATE_NAME and child:IsA("BasePart") then
				megaPlot = child
				print("[MegaPlotVisibility] Found MegaPlot in descendants!")
				break
			end
		end
	end
	
	if not megaPlot then
		warn("[MegaPlotVisibility] MegaPlot baseplate not found!")
		warn("[MegaPlotVisibility] Children of MegaPlotRoom:")
		for _, child in ipairs(megaPlotRoom:GetChildren()) do
			warn("  -", child.Name, "(", child.ClassName, ")")
		end
		return nil
	end
	
	print("[MegaPlotVisibility] Found MegaPlot baseplate!")
	print("[MegaPlotVisibility] Position:", megaPlot.Position)
	print("[MegaPlotVisibility] Size:", megaPlot.Size)
	
	-- Create BuildArea equivalent for MegaPlot
	buildArea = Instance.new("Folder")
	buildArea.Name = "MegaPlotBuildArea"
	buildArea.Parent = megaPlotRoom
	
	-- Set up attributes similar to regular BuildAreas
	if megaPlot:IsA("BasePart") then
		local posX = megaPlot.Position.X
		local posZ = megaPlot.Position.Z
		local sizeX = megaPlot.Size.X
		local sizeZ = megaPlot.Size.Z
		local plateTop = megaPlot.Position.Y + megaPlot.Size.Y / 2
		
		print(string.format("[MegaPlotVisibility] Setting attributes: posX=%.1f, posZ=%.1f, sizeX=%.1f, sizeZ=%.1f, plateTop=%.1f",
			posX, posZ, sizeX, sizeZ, plateTop))
		
		buildArea:SetAttribute("BasePlatePositionX", posX)
		buildArea:SetAttribute("BasePlatePositionY", megaPlot.Position.Y)
		buildArea:SetAttribute("BasePlatePositionZ", posZ)
		buildArea:SetAttribute("BasePlateSizeX", sizeX)
		buildArea:SetAttribute("BasePlateSizeY", megaPlot.Size.Y)
		buildArea:SetAttribute("BasePlateSizeZ", sizeZ)
		buildArea:SetAttribute("BasePlateTop", plateTop)
	end
	
	-- Create Blocks folder
	local blocksFolder = Instance.new("Folder")
	blocksFolder.Name = "Blocks"
	blocksFolder.Parent = buildArea
	print("[MegaPlotVisibility] Created MegaPlotBuildArea with Blocks folder")
	
	return buildArea
end

local function setupMegaPlotTerrain(biome, terrainStyle, season, seed)
	print("[MegaPlotVisibility] setupMegaPlotTerrain called:", biome, terrainStyle, season, "seed:", seed or "random")
	
	-- Prevent duplicate generation
	if terrainGenerationInProgress then
		print("[MegaPlotVisibility] Terrain generation already in progress, skipping")
		return nil
	end
	terrainGenerationInProgress = true
	
	print("[MegaPlotVisibility] megaPlotRoom:", megaPlotRoom and megaPlotRoom.Name or "NIL")
	
	-- Mark terrain as not ready while generating
	megaPlotTerrainReady = false
	if terrainReadyValue then
		terrainReadyValue.Value = false
	end
	
	-- Reset progress bar to 0
	local progressValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainProgress")
	if progressValue then
		progressValue.Value = 0
	end
	
	local buildArea = getMegaPlotBuildArea()
	if not buildArea then
		warn("[MegaPlotVisibility] Cannot setup terrain - no build area!")
		return nil
	end
	
	print("[MegaPlotVisibility] Got buildArea:", buildArea.Name)
	
	-- Hide the MegaPlot baseplate (like regular plots do)
	local megaPlot = nil
	if megaPlotRoom then
		megaPlot = megaPlotRoom:FindFirstChild(MEGAPLOT_BASEPLATE_NAME)
		if not megaPlot then
			for _, child in ipairs(megaPlotRoom:GetDescendants()) do
				if child.Name == MEGAPLOT_BASEPLATE_NAME and child:IsA("BasePart") then
					megaPlot = child
					break
				end
			end
		end
	end
	
	print("[MegaPlotVisibility] Found megaPlot baseplate:", megaPlot and megaPlot.Name or "NIL")
	
	if megaPlot and megaPlot:IsA("BasePart") then
		print("[MegaPlotVisibility] Hiding MegaPlot baseplate")
		megaPlot.Transparency = 1
		megaPlot.CanCollide = false
		megaPlot.CanQuery = false  -- Prevent raycasts from hitting the invisible baseplate
	else
		warn("[MegaPlotVisibility] Could not find MegaPlot baseplate to hide!")
	end
	
	-- Set biome/terrain attributes
	buildArea:SetAttribute("CurrentBiome", biome or "Plains")
	buildArea:SetAttribute("TerrainStyle", terrainStyle or "Flat")
	buildArea:SetAttribute("CurrentSeason", season or "Summer")
	
	print("[MegaPlotVisibility] Attributes set, calling TerrainGenerator...")
	
	-- Generate terrain using TerrainGenerator
	local Modules = ServerScriptService:WaitForChild("Modules", 5)
	if Modules then
		local TerrainGenerator = require(Modules:WaitForChild("TerrainGenerator"))
		if TerrainGenerator then
			print("[MegaPlotVisibility] Generating MegaPlot terrain:", biome, terrainStyle)
			
			-- CRITICAL: Disable animations and layer delay for mega plot (way too many blocks)
			local originalSettings = TerrainGenerator.GetGenerationSettings()
			TerrainGenerator.SetGenerationSettings({ 
				LAYER_DELAY = 0,
				ANIMATION_ENABLED = false 
			})
			
			-- Use plot number 0 for MegaPlot
			-- NOTE: Terrain generators are synchronous (yield internally but return when done)
			local blocksCreated
			if terrainStyle == "Default" then
			 -- Multi-biome world generation with optional seed
			 blocksCreated = TerrainGenerator.GenerateDefaultTerrain(buildArea, 0, seed)
			else
			blocksCreated = TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, 0, biome or "Plains", terrainStyle or "Flat", seed)
			end
			
			-- Restore original settings
			TerrainGenerator.SetGenerationSettings({ 
				LAYER_DELAY = originalSettings.LAYER_DELAY,
				ANIMATION_ENABLED = originalSettings.ANIMATION_ENABLED 
			})
			
			-- Set progress to 100% now that generation is complete
			local progressValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainProgress")
			if progressValue then
				progressValue.Value = 1
			end
			
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			local blockCount = blocksFolder and #blocksFolder:GetChildren() or 0
			print("[MegaPlotVisibility] Terrain generation complete!", blockCount, "blocks created (", blocksCreated or 0, "reported by generator)")
		else
			warn("[MegaPlotVisibility] TerrainGenerator module not found!")
		end
		
		-- Register MegaPlotBuildArea with GrassSpreadManager (plot 0 for MegaPlot)
		-- Load from same Modules folder that TerrainGenerator was found in
		local grassModule = Modules:FindFirstChild("GrassSpreadManager")
		if grassModule then
			local gsm = require(grassModule)
			if gsm then
				if not gsm.IsActive or not gsm.IsActive() then
					gsm.Initialize()
				end
				gsm.RegisterPlot(buildArea, 0)
				print("[MegaPlotVisibility] Registered MegaPlotBuildArea with GrassSpreadManager (plot 0)")
			else
				warn("[MegaPlotVisibility] GrassSpreadManager require returned nil!")
			end
		else
			warn("[MegaPlotVisibility] GrassSpreadManager module not found in Modules folder!")
			warn("[MegaPlotVisibility] Modules children:")
			for _, child in ipairs(Modules:GetChildren()) do
				warn("  -", child.Name, "(", child.ClassName, ")")
			end
		end
	else
		warn("[MegaPlotVisibility] Modules folder not found!")
	end
	
	-- Mark terrain as ready
	megaPlotTerrainReady = true
	terrainGenerationInProgress = false
	if terrainReadyValue then
		terrainReadyValue.Value = true
		print("[MegaPlotVisibility] MegaPlot terrain ready!")
	end
	
	-- Mark save as dirty so terrain gen gets persisted
	if _G.MegaPlotSaveManager and _G.MegaPlotSaveManager.MarkDirty then
		_G.MegaPlotSaveManager.MarkDirty()
		print("[MegaPlotVisibility] Marked MegaPlot save as dirty after terrain generation")
	end
	
	return buildArea
end

local function clearMegaPlotTerrain()
	if not megaPlotRoom then return end
	
	-- Unregister from GrassSpreadManager
	local Modules = ServerScriptService:FindFirstChild("Modules")
	if Modules then
		local grassModule = Modules:FindFirstChild("GrassSpreadManager")
		if grassModule then
			local gsm = require(grassModule)
			if gsm then
				gsm.UnregisterPlot(0)
				print("[MegaPlotVisibility] Unregistered MegaPlot from GrassSpreadManager")
			end
		end
	end
	
	-- Reset generation state
	terrainGenerationInProgress = false
	megaPlotTerrainReady = false
	if terrainReadyValue then
		terrainReadyValue.Value = false
	end
	
	local buildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
	if buildArea then
		local Modules = ServerScriptService:WaitForChild("Modules", 5)
		if Modules then
			local TerrainGenerator = require(Modules:WaitForChild("TerrainGenerator"))
			if TerrainGenerator then
				print("[MegaPlotVisibility] Clearing MegaPlot terrain")
				TerrainGenerator.ClearAllBlocks(buildArea, 0)
			end
		end
	end
end

-- ============================================
-- MODE SWITCHING
-- (Defined AFTER terrain functions it calls)
-- ============================================

local currentMode = "Individual"

local function applyMode(mode, skipTerrain)
	print("[MegaPlotVisibility] Applying mode:", mode, "| skipTerrain:", skipTerrain)
	
	local previousMode = currentMode
	currentMode = mode
	
	if mode == "MegaPlot" then
		-- CRITICAL: Reset terrain ready state so teleport waiter doesn't fire prematurely
		-- (especially important for skipTerrain=true where PrivateServerSettingsHandler generates terrain)
		megaPlotTerrainReady = false
		if terrainReadyValue then
			terrainReadyValue.Value = false
		end
		
		-- Show MegaPlot room
		-- NOTE: We do NOT hide individual BuildAreas anymore to preserve sign functionality
		showMegaPlotRoom()
		
		-- Ensure baseplate is hidden (important on startup when loading saved MegaPlot mode)
		ensureBaseplateHidden()
		
		-- Create spawn point at safe height for MegaPlot BEFORE terrain generates
		if megaPlotRoom then
			local megaPlotSpawn = megaPlotRoom:FindFirstChild("MegaPlotSpawn")
			if not megaPlotSpawn then
				megaPlotSpawn = Instance.new("SpawnLocation")
				megaPlotSpawn.Name = "MegaPlotSpawn"
				megaPlotSpawn.Anchored = true
				megaPlotSpawn.CanCollide = false
				megaPlotSpawn.Transparency = 1
				megaPlotSpawn.Size = Vector3.new(6, 1, 6)
				megaPlotSpawn.Position = Vector3.new(1247, 200, -79)  -- High up safe position
				megaPlotSpawn.Neutral = true  -- Any team can spawn here
				megaPlotSpawn.Parent = megaPlotRoom
				print("[MegaPlotVisibility] Created MegaPlotSpawn at safe height")
			end
			
			-- Set all current players to spawn at MegaPlot immediately
			for _, player in ipairs(Players:GetPlayers()) do
				player.RespawnLocation = megaPlotSpawn
				print("[MegaPlotVisibility] Set", player.Name, "spawn to MegaPlotSpawn")
			end
		end
		
		-- Generate terrain if not skipping (on startup, generate with default/saved settings)
		if not skipTerrain then
			task.spawn(function()
				-- Wait for room to be fully visible
				task.wait(0.3)
				
				-- Check if there's saved mega plot data for this private server
				local megaPlotSaveManager = nil
				local waitForSave = 0
				while not _G.MegaPlotSaveManager and waitForSave < 10 do
					task.wait(0.2)
					waitForSave = waitForSave + 0.2
				end
				megaPlotSaveManager = _G.MegaPlotSaveManager
				
				local loadedSuccessfully = false
				
				if megaPlotSaveManager then
					-- Priority: slot data first (lastPlayedSlot → slot 1 fallback), then legacy main key
					local DataStoreService = game:GetService("DataStoreService")
					local PrivateServerManager = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("PrivateServerManager"))
					local serverId = PrivateServerManager.GetServerId()
					
					if serverId and serverId ~= "" then
						local slotDS = nil
						pcall(function() slotDS = DataStoreService:GetDataStore("MegaPlotSlots_v1") end)
						
						if slotDS then
							-- Determine which slot to load: lastPlayedSlot, or default to slot 1
							local metaKey = serverId .. "_slotmeta"
							local metaSuccess, metadata = pcall(function() return slotDS:GetAsync(metaKey) end)
							
							local slotToLoad = nil
							if metaSuccess and metadata and metadata.lastPlayedSlot then
								slotToLoad = metadata.lastPlayedSlot
								print("[MegaPlotVisibility] Last played slot:", slotToLoad)
							else
								-- No lastPlayedSlot — default to slot 1
								slotToLoad = 1
								print("[MegaPlotVisibility] No lastPlayedSlot, defaulting to slot 1")
							end
							
							local slotKey = serverId .. "_slot_" .. tostring(slotToLoad)
							local slotSuccess, slotData = pcall(function() return slotDS:GetAsync(slotKey) end)
							
							if slotSuccess and slotData and slotData.data then
								print("[MegaPlotVisibility] Loading from slot", slotToLoad, "...")
								local buildArea = getMegaPlotBuildArea()
								if buildArea then
									ensureBaseplateHidden()
									local loadOk, loadResult = megaPlotSaveManager.LoadFromData(slotData.data, buildArea)
									if loadOk then
										print("[MegaPlotVisibility] Loaded from slot", slotToLoad, ":", loadResult, "blocks")
										loadedSuccessfully = true
										-- Set active slot so auto-saves go to the right place
										if megaPlotSaveManager.SetActiveSlot then
											megaPlotSaveManager.SetActiveSlot(slotToLoad)
										end
									else
										warn("[MegaPlotVisibility] Failed to load from slot", slotToLoad, ":", loadResult)
									end
								end
							else
								print("[MegaPlotVisibility] Slot", slotToLoad, "has no data")
							end
						end
					end
					
					-- Legacy fallback: try the old main save key if no slot data loaded
					if not loadedSuccessfully then
						local hasSave = megaPlotSaveManager.CheckForSavedData()
						if hasSave then
							print("[MegaPlotVisibility] No slot data, trying legacy main save key...")
							local buildArea = getMegaPlotBuildArea()
							if buildArea then
								ensureBaseplateHidden()
								local success, blockCount = megaPlotSaveManager.Load(buildArea)
								if success then
									print("[MegaPlotVisibility] Loaded from legacy save:", blockCount, "blocks")
									loadedSuccessfully = true
								else
									warn("[MegaPlotVisibility] Failed to load legacy save:", blockCount)
								end
							end
						end
					end
				end
				
				if loadedSuccessfully then
					-- Register with GrassSpreadManager
					local buildArea = getMegaPlotBuildArea()
					if buildArea then
						local gsModules = ServerScriptService:WaitForChild("Modules", 5)
						if gsModules then
							local grassModule = gsModules:FindFirstChild("GrassSpreadManager")
							if grassModule then
								local gsm = require(grassModule)
								if gsm then
									if not gsm.IsActive or not gsm.IsActive() then gsm.Initialize() end
									gsm.RegisterPlot(buildArea, 0)
								end
							end
						end
					end
					
					-- Mark terrain as ready
					megaPlotTerrainReady = true
					terrainGenerationInProgress = false
					if terrainReadyValue then terrainReadyValue.Value = true end
					
					return -- Done! Skip fresh terrain generation
				end
				
				-- No saved data (or load failed) - generate fresh terrain
				local biome = "Plains"
				local terrainStyle = "Flat"
				local season = "Summer"
				
				-- Try to get settings from an existing BuildArea (they share settings)
				for name, data in pairs(individualBuildAreas) do
					local ba = data.buildArea
					if ba then
						biome = ba:GetAttribute("CurrentBiome") or biome
						terrainStyle = ba:GetAttribute("TerrainStyle") or terrainStyle
						season = ba:GetAttribute("CurrentSeason") or season
						print("[MegaPlotVisibility] Got settings from", name, "-", biome, terrainStyle, season)
						break
					end
				end
				
				print("[MegaPlotVisibility] No saved data, generating fresh terrain for MegaPlot:", biome, terrainStyle, season)
				setupMegaPlotTerrain(biome, terrainStyle, season)
			end)
		end
		
		-- Teleport all players to MegaPlot once terrain is ready
		task.spawn(function()
			-- Wait for terrain to be ready (with timeout)
			local maxWait = 90 -- Allow plenty of time for large mega plots
			local waited = 0
			while not megaPlotTerrainReady and waited < maxWait do
				task.wait(0.5)
				waited = waited + 0.5
				-- Abort if mode changed while waiting (e.g. switched to Individual)
				if currentMode ~= "MegaPlot" then
					print("[MegaPlotVisibility] Mode changed to", currentMode, "while waiting for terrain - aborting teleport")
					return
				end
			end
			
			-- Final mode check after wait completes
			if currentMode ~= "MegaPlot" then
				print("[MegaPlotVisibility] Mode is no longer MegaPlot - aborting teleport")
				return
			end
			
			if megaPlotTerrainReady then
				print("[MegaPlotVisibility] Terrain ready, teleporting all players...")
			else
				warn("[MegaPlotVisibility] Terrain generation timed out after", maxWait, "s, teleporting anyway")
			end
			
			-- Update MegaPlotSpawn position to sit above actual terrain
			-- so death respawns also land correctly
			if megaPlotRoom then
				local megaPlotSpawn = megaPlotRoom:FindFirstChild("MegaPlotSpawn")
				if megaPlotSpawn then
					local safePos = getMegaPlotSpawnPosition()
					if safePos then
						megaPlotSpawn.Position = safePos + Vector3.new(0, 1, 0) -- Slightly above spawn pos
						print("[MegaPlotVisibility] Updated MegaPlotSpawn to terrain-aware position:", megaPlotSpawn.Position)
					end
				end
			end
			
			task.wait(0.3)
			teleportAllPlayersToMegaPlot(true) -- keepProtection until client loading screen dismisses
		end)
	else
		-- Switching to Individual mode
		
		if skipTerrain then
			-- PrivateServerSettingsHandler is managing the full transition
			-- (terrain regen, teleporting, loading screen, etc.)
			-- Don't hide the room or teleport players prematurely
			print("[MegaPlotVisibility] Individual mode (skipTerrain) - handler manages transition")
		else
			-- Direct mode switch (startup/no handler) - do everything here
			hideMegaPlotRoom()
			
			-- Clear RespawnLocation for all players so they respawn at individual plots
			for _, player in ipairs(Players:GetPlayers()) do
				player.RespawnLocation = nil
			end
			
			-- If we were previously in MegaPlot mode, teleport players to their individual plots
			if previousMode == "MegaPlot" then
				task.spawn(function()
					task.wait(0.3)  -- Small delay to let things settle
					teleportAllPlayersToIndividualPlots()
				end)
			end
		end
	end
end

-- ============================================
-- INITIALIZATION
-- ============================================

-- Guard against duplicate initialization (use global to work across script instances)
if _G.MegaPlotVisibilityInitialized then
	print("[MegaPlotVisibility] Already initialized globally, skipping duplicate script")
	return {}
end
_G.MegaPlotVisibilityInitialized = true

local function initialize()
	
	print("[MegaPlotVisibility] Initializing...")
	
	-- Find MegaPlotRoom
	megaPlotRoom = findMegaPlotRoom()
	
	if megaPlotRoom then
		print("[MegaPlotVisibility] Found MegaPlotRoom")
	else
		print("[MegaPlotVisibility] MegaPlotRoom not found - will be hidden by default")
	end
	
	-- Find individual build areas
	individualBuildAreas = findIndividualBuildAreas()
	
	local count = 0
	for _ in pairs(individualBuildAreas) do count = count + 1 end
	print("[MegaPlotVisibility] Found", count, "individual build areas")
	
	-- Wait for private server values
	local isPrivateServerValue = ReplicatedStorage:WaitForChild("IsPrivateServer", 15)
	local modeValue = ReplicatedStorage:WaitForChild("PrivateServerMode", 15)
	
	-- Check if this is a private server
	if not isPrivateServerValue or not isPrivateServerValue.Value then
		-- Public server - always hide MegaPlotRoom, show individual plots
		print("[MegaPlotVisibility] Public server - hiding MegaPlotRoom")
		hideMegaPlotRoom()
		return
	end
	
	-- Create terrain ready value for clients to check
	terrainReadyValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainReady")
	if not terrainReadyValue then
		terrainReadyValue = Instance.new("BoolValue")
		terrainReadyValue.Name = "MegaPlotTerrainReady"
		terrainReadyValue.Value = false
		terrainReadyValue.Parent = ReplicatedStorage
	end
	
	-- Create remote for showing loading screen to all clients
	local RemotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not RemotesFolder then
		RemotesFolder = Instance.new("Folder")
		RemotesFolder.Name = "Remotes"
		RemotesFolder.Parent = ReplicatedStorage
	end
	showLoadingScreenRemote = RemotesFolder:FindFirstChild("ShowMegaPlotLoadingScreen")
	if not showLoadingScreenRemote then
		showLoadingScreenRemote = Instance.new("RemoteEvent")
		showLoadingScreenRemote.Name = "ShowMegaPlotLoadingScreen"
		showLoadingScreenRemote.Parent = RemotesFolder
	end
	
	-- Create a NumberValue for terrain generation progress (0-1)
	local progressValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainProgress")
	if not progressValue then
		progressValue = Instance.new("NumberValue")
		progressValue.Name = "MegaPlotTerrainProgress"
		progressValue.Value = 0
		progressValue.Parent = ReplicatedStorage
	end
	
	-- Pre-create MegaPlotSpawn if we're going to be in MegaPlot mode
	-- This needs to happen BEFORE applyMode so players spawn safely
	local currentModeStr = modeValue and modeValue.Value or "Individual"
	if currentModeStr == "MegaPlot" and megaPlotRoom then
		local megaPlotSpawn = megaPlotRoom:FindFirstChild("MegaPlotSpawn")
		if not megaPlotSpawn then
			megaPlotSpawn = Instance.new("SpawnLocation")
			megaPlotSpawn.Name = "MegaPlotSpawn"
			megaPlotSpawn.Anchored = true
			megaPlotSpawn.CanCollide = false
			megaPlotSpawn.Transparency = 1
			megaPlotSpawn.Size = Vector3.new(6, 1, 6)
			megaPlotSpawn.Position = Vector3.new(1247, 200, -79)  -- High up safe position
			megaPlotSpawn.Neutral = true  -- Any team can spawn here
			megaPlotSpawn.Parent = megaPlotRoom
			print("[MegaPlotVisibility] Pre-created MegaPlotSpawn at safe height")
		end
		
		-- Set spawn for any existing players immediately
		for _, player in ipairs(Players:GetPlayers()) do
			player.RespawnLocation = megaPlotSpawn
			print("[MegaPlotVisibility] Pre-set", player.Name, "spawn to MegaPlotSpawn")
			
			-- If they already have a character, anchor it immediately and add ForceField
			if player.Character then
				local hrp = player.Character:FindFirstChild("HumanoidRootPart")
				if hrp then
					hrp.Anchored = true
					hrp.CFrame = CFrame.new(1247, 200, -79)
					print("[MegaPlotVisibility] Pre-anchored", player.Name, "at safe position")
					
					-- Add ForceField for protection
					if not player.Character:FindFirstChild("LoadingProtection") then
						local ff = Instance.new("ForceField")
						ff.Name = "LoadingProtection"
						ff.Visible = false
						ff.Parent = player.Character
					end
				end
			end
		end
	end
	
	-- Private server - apply current mode
	applyMode(currentModeStr)
	
	-- Listen for mode changes (from PrivateServerSettingsHandler)
	-- Skip terrain here because PrivateServerSettingsHandler handles terrain generation with user's settings
	if modeValue then
		modeValue.Changed:Connect(function(newMode)
			print("[MegaPlotVisibility] Mode changed to:", newMode, "(via modeValue.Changed)")
			applyMode(newMode, true)  -- skipTerrain=true, handler generates terrain with user's settings
		end)
	end
end

-- ============================================
-- PUBLIC API (for PrivateServerSettingsHandler)
-- ============================================

local MegaPlotVisibility = {}

function MegaPlotVisibility.GetMegaPlotRoom()
	return megaPlotRoom
end

function MegaPlotVisibility.GetMegaPlotBuildArea()
	return getMegaPlotBuildArea()
end

function MegaPlotVisibility.SetupTerrain(biome, terrainStyle, season, seed)
	return setupMegaPlotTerrain(biome, terrainStyle, season, seed)
end

function MegaPlotVisibility.ClearTerrain()
	clearMegaPlotTerrain()
end

function MegaPlotVisibility.ApplyMode(mode, skipTerrain)
	applyMode(mode, skipTerrain)
end

function MegaPlotVisibility.IsVisible()
	return megaPlotRoom and megaPlotRoom.Parent == Workspace
end

function MegaPlotVisibility.HideMegaPlotRoom()
	hideMegaPlotRoom()
	-- Clear RespawnLocation so players respawn at individual plots
	for _, player in ipairs(Players:GetPlayers()) do
		player.RespawnLocation = nil
	end
end

function MegaPlotVisibility.RefreshBuildAreas()
	individualBuildAreas = findIndividualBuildAreas()
end

function MegaPlotVisibility.TeleportPlayer(player)
	return teleportPlayerToMegaPlot(player)
end

function MegaPlotVisibility.TeleportAllPlayers()
	teleportAllPlayersToMegaPlot()
end

function MegaPlotVisibility.GetSpawnPosition()
	return getMegaPlotSpawnPosition()
end

function MegaPlotVisibility.GetCurrentMode()
	return currentMode
end

function MegaPlotVisibility.IsTerrainReady()
	return megaPlotTerrainReady
end

function MegaPlotVisibility.ShowLoadingScreenToAllClients(reason)
	-- CRITICAL: Set terrain as not ready BEFORE firing to clients
	-- This prevents the client from immediately hiding the loading screen
	megaPlotTerrainReady = false
	if terrainReadyValue then
		terrainReadyValue.Value = false
	end
	
	if showLoadingScreenRemote then
		print("[MegaPlotVisibility] Firing ShowMegaPlotLoadingScreen to all clients:", reason or "terrain reset")
		showLoadingScreenRemote:FireAllClients(reason)
	else
		warn("[MegaPlotVisibility] ShowMegaPlotLoadingScreen remote not available!")
	end
end

-- Run initialization
initialize()

-- Force player spawn location to MegaPlot area
-- (Must be defined BEFORE functions that call it)
local function setPlayerSpawnToMegaPlot(player)
	if currentMode ~= "MegaPlot" then return end
	if not megaPlotRoom then return end
	
	-- Find existing spawn location in MegaPlot (should be created by applyMode)
	local megaPlotSpawn = megaPlotRoom:FindFirstChild("MegaPlotSpawn")
	if not megaPlotSpawn then
		-- Create it if missing — use terrain-aware position if terrain is loaded
		local spawnPos = Vector3.new(1247, 200, -79) -- Default high up safe position
		if megaPlotTerrainReady then
			local terrainPos = getMegaPlotSpawnPosition()
			if terrainPos then
				spawnPos = terrainPos + Vector3.new(0, 1, 0)
			end
		end
		
		megaPlotSpawn = Instance.new("SpawnLocation")
		megaPlotSpawn.Name = "MegaPlotSpawn"
		megaPlotSpawn.Anchored = true
		megaPlotSpawn.CanCollide = false
		megaPlotSpawn.Transparency = 1
		megaPlotSpawn.Size = Vector3.new(6, 1, 6)
		megaPlotSpawn.Position = spawnPos
		megaPlotSpawn.Neutral = true  -- Any team can spawn here
		megaPlotSpawn.Parent = megaPlotRoom
		print("[MegaPlotVisibility] Created MegaPlotSpawn at", spawnPos, "(in setPlayerSpawnToMegaPlot)")
	end
	
	-- Set player's respawn location
	player.RespawnLocation = megaPlotSpawn
	print("[MegaPlotVisibility] Set", player.Name, "spawn to MegaPlotSpawn")
end

-- Helper to safely teleport player when terrain is ready
local function safeTeleportToMegaPlot(player, forceField)
	if currentMode ~= "MegaPlot" then 
		if forceField and forceField.Parent then forceField:Destroy() end
		return 
	end
	
	local character = player.Character
	if not character then 
		if forceField and forceField.Parent then forceField:Destroy() end
		return 
	end
	
	local humanoid = character:FindFirstChild("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then 
		if forceField and forceField.Parent then forceField:Destroy() end
		return 
	end
	
	-- IMMEDIATELY anchor to prevent falling death
	hrp.Anchored = true
	
	-- Move to safe position high above the MegaPlot
	local safePos = getMegaPlotSpawnPosition()
	if safePos then
		character:PivotTo(CFrame.new(safePos + Vector3.new(0, 100, 0)))  -- 100 studs above spawn
	else
		-- Fallback: just move them high up
		character:PivotTo(CFrame.new(1247, 200, -79))
	end
	
	print("[MegaPlotVisibility] Player", player.Name, "anchored safely, waiting for terrain...")
	
	-- If terrain is already ready, teleport immediately
	if megaPlotTerrainReady then
		print("[MegaPlotVisibility] Terrain already ready, teleporting", player.Name)
		hrp.Anchored = false
		if forceField and forceField.Parent then forceField:Destroy() end
		teleportPlayerToMegaPlot(player, true) -- keepProtection until title screen dismissed
		return
	end
	
	-- Wait for terrain to be ready
	local maxWait = 60
	local waited = 0
	while not megaPlotTerrainReady and waited < maxWait do
		task.wait(0.2)
		waited = waited + 0.2
		
		-- Check if player left or character changed
		if not player.Parent or player.Character ~= character then
			if forceField and forceField.Parent then forceField:Destroy() end
			return
		end
		
		-- Abort if mode changed while waiting (e.g. switched to Individual)
		if currentMode ~= "MegaPlot" then
			print("[MegaPlotVisibility] Mode changed during safeTeleport wait - aborting for", player.Name)
			if hrp and hrp.Parent then hrp.Anchored = false end
			if forceField and forceField.Parent then forceField:Destroy() end
			return
		end
	end
	
	-- Unanchor and teleport
	if hrp and hrp.Parent then
		hrp.Anchored = false
	end
	
	-- Remove ForceField
	if forceField and forceField.Parent then 
		forceField:Destroy() 
	end
	
	if currentMode == "MegaPlot" and player.Character == character then
		print("[MegaPlotVisibility] Terrain ready, teleporting", player.Name)
		teleportPlayerToMegaPlot(player, true) -- keepProtection until title screen dismissed
	end
end

-- Immediately handle character spawn to prevent death
local function onCharacterSpawned(player, character)
	if currentMode ~= "MegaPlot" then return end
	
	-- Wait for HumanoidRootPart to exist (very brief wait)
	local hrp = character:WaitForChild("HumanoidRootPart", 3)
	if not hrp then return end
	
	local humanoid = character:FindFirstChild("Humanoid")
	
	-- Anchor IMMEDIATELY - this is critical to prevent falling death
	hrp.Anchored = true
	
	-- Add ForceField to prevent any damage while loading
	local forceField = Instance.new("ForceField")
	forceField.Name = "LoadingProtection"
	forceField.Visible = false  -- Invisible protection
	forceField.Parent = character
	
	-- Move to safe position high above the MegaPlot RIGHT AWAY
	local safePos = Vector3.new(1247, 200, -79)  -- Hardcoded safe position, 200 studs up
	hrp.CFrame = CFrame.new(safePos)
	
	print("[MegaPlotVisibility] Player", player.Name, "anchored at safe position with ForceField")
	
	-- Also set their respawn location in case they die
	setPlayerSpawnToMegaPlot(player)
	
	-- Now do the safe teleport (which will handle waiting for terrain and removing ForceField)
	task.spawn(function()
		safeTeleportToMegaPlot(player, forceField)
	end)
end

-- Very early character handling - catches character before physics fully applies
local function setupEarlyCharacterHandling(player)
	if currentMode ~= "MegaPlot" then return end
	
	-- Set spawn location immediately
	setPlayerSpawnToMegaPlot(player)
	
	-- Use DescendantAdded to catch HumanoidRootPart the moment it's created
	local connection
	connection = player.DescendantAdded:Connect(function(descendant)
		if descendant.Name == "HumanoidRootPart" and descendant:IsA("BasePart") then
			-- Anchor IMMEDIATELY
			descendant.Anchored = true
			descendant.CFrame = CFrame.new(1247, 200, -79)
			print("[MegaPlotVisibility] EARLY: Anchored", player.Name, "via DescendantAdded")
			
			-- Add ForceField for protection
			local character = descendant.Parent
			if character and not character:FindFirstChild("LoadingProtection") then
				local ff = Instance.new("ForceField")
				ff.Name = "LoadingProtection"
				ff.Visible = false
				ff.Parent = character
			end
		end
	end)
	
	-- Clean up after a short time
	task.delay(10, function()
		if connection then
			connection:Disconnect()
		end
	end)
end

-- Handle players joining when in MegaPlot mode
Players.PlayerAdded:Connect(function(player)
	if currentMode ~= "MegaPlot" then return end
	
	-- Set spawn location BEFORE character spawns
	setPlayerSpawnToMegaPlot(player)
	
	if player.Character then
		onCharacterSpawned(player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		onCharacterSpawned(player, character)
	end)
end)

-- Also handle existing players and respawns
for _, player in ipairs(Players:GetPlayers()) do
	if currentMode == "MegaPlot" then
		-- Set spawn location for existing players
		setPlayerSpawnToMegaPlot(player)
		
		if player.Character then
			onCharacterSpawned(player, player.Character)
		end
	end
	player.CharacterAdded:Connect(function(character)
		if currentMode ~= "MegaPlot" then return end
		onCharacterSpawned(player, character)
	end)
end

-- ============================================
-- PLAYER READY REMOTE (release protection when title screen dismissed)
-- ============================================

local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = ReplicatedStorage
end

local PlayerReadyRemote = Instance.new("RemoteEvent")
PlayerReadyRemote.Name = "MegaPlotPlayerReady"
PlayerReadyRemote.Parent = Remotes

PlayerReadyRemote.OnServerEvent:Connect(function(player)
	print("[MegaPlotVisibility] Player", player.Name, "signaled ready (title screen dismissed)")
	releasePlayerProtection(player)
end)

-- Clean up protection tracking when players leave
Players.PlayerRemoving:Connect(function(player)
	playerProtection[player] = nil
end)

-- Store module globally for other scripts to access
_G.MegaPlotVisibility = MegaPlotVisibility

return MegaPlotVisibility
