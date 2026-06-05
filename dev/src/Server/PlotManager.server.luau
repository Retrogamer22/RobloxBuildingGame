--[[
	PlotManager
	Handles plot assignment, ownership, spawn management, and terrain generation
	
	On server start: generates terrain for all plots and removes baseplates
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local NetherConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("NetherConfig"))
local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

-- Helper to check if MegaPlot mode is active
local function isMegaPlotMode()
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	return modeValue and modeValue.Value == "MegaPlot"
end

-- Wait for modules folder and require modules
local TerrainGenerator = nil
local ChunkTerrainManager = nil
local ChunkStreamManager = nil -- SECOND-PLACE streaming loader (shared-world)
local GrassSpreadManager = nil
local SnowyGrassManager = nil
local WeatherManager = nil

-- Free-build (second place) detection. The place ID lives in BetaConfig (single
-- source of truth, shared with SaveManager's persistence gate). chunk terrain is
-- still loaded everywhere but only invoked when isChunkPlace() is true.
local function isChunkPlace()
	return BetaConfig.IsFreeBuildPlace()
end
do
	local modulesFolder = script.Parent:WaitForChild("Modules", 10)
	if modulesFolder then
		local terrainModule = modulesFolder:WaitForChild("TerrainGenerator", 10)
		if terrainModule then
			TerrainGenerator = require(terrainModule)
			print("[PlotManager] TerrainGenerator loaded")
		end

		-- SECOND-PLACE ONLY: chunk terrain. Loaded everywhere but only invoked
		-- when game.PlaceId matches the chunk place (see CHUNK_PLACE_IDS above).
		local chunkModule = modulesFolder:FindFirstChild("ChunkTerrainManager")
		if chunkModule then
			ChunkTerrainManager = require(chunkModule)
			if TerrainGenerator then
				ChunkTerrainManager.Init(TerrainGenerator)
				print("[PlotManager] ChunkTerrainManager loaded")
			end
		end

		-- SECOND-PLACE streaming loader (shared-world). Reuses TerrainGenerator like
		-- ChunkTerrainManager, but streams small chunks around the UNION of all players
		-- in one shared world. Only started on chunk places (see onFreeBuildPlayerAdded).
		local streamModule = modulesFolder:FindFirstChild("ChunkStreamManager")
		if streamModule then
			ChunkStreamManager = require(streamModule)
			if ChunkStreamManager and TerrainGenerator then
				ChunkStreamManager.Init(TerrainGenerator)
				print("[PlotManager] ChunkStreamManager loaded")
			end
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
		end
		
		local weatherModule = modulesFolder:WaitForChild("WeatherManager", 10)
		if weatherModule then
			WeatherManager = require(weatherModule)
		end
	end
end

-- TEMP DIAGNOSTIC: confirm chunk wiring at runtime. Remove once verified.
print(string.format(
	"[BB-CHUNK] startup: PlaceId=%d isChunkPlace=%s ChunkTerrainManager=%s",
	game.PlaceId,
	tostring(isChunkPlace()),
	tostring(ChunkTerrainManager ~= nil)
))

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

-- The paired nether plot for an overworld plot number (NetherPlot{N}).
local function getNetherPlot(plotNumber)
	return workspace:FindFirstChild(NetherConfig.NETHER_PLOT_PREFIX .. plotNumber)
end

-- Ensure a nether plot has its baseplate attributes cached (mirrors how
-- initializeAllPlots does it for overworld plots). NetherPlots are hand-placed
-- in Studio and may not have these set; the cave generator needs them. Unlike
-- overworld, we do NOT destroy the nether baseplate — it's the floor reference.
local function ensureNetherPlotAttributes(netherPlot)
	if netherPlot:GetAttribute("BasePlateSizeX") then return true end
	local basePlate = netherPlot:FindFirstChild("BasePlate")
		 or (netherPlot:IsA("BasePart") and netherPlot or nil)
	if not basePlate or not basePlate:IsA("BasePart") then
		warn("[PlotManager] NetherPlot " .. netherPlot.Name .. " has no BasePlate to derive attributes from")
		return false
	end
	netherPlot:SetAttribute("BasePlatePositionX", basePlate.Position.X)
	netherPlot:SetAttribute("BasePlatePositionY", basePlate.Position.Y)
	netherPlot:SetAttribute("BasePlatePositionZ", basePlate.Position.Z)
	netherPlot:SetAttribute("BasePlateSizeX", basePlate.Size.X)
	netherPlot:SetAttribute("BasePlateSizeY", basePlate.Size.Y)
	netherPlot:SetAttribute("BasePlateSizeZ", basePlate.Size.Z)
	netherPlot:SetAttribute("BasePlateTop", basePlate.Position.Y + basePlate.Size.Y / 2)
	return true
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
	-- SECOND-PLACE ONLY: no pre-placed BuildArea models exist here. Fabricate one
	-- at the world origin so the chunk generator has a container + anchor.
	if not buildArea and isChunkPlace() and ChunkTerrainManager then
		buildArea = ChunkTerrainManager.EnsureCenterBuildArea(plotNumber)
	end
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
			
			if isChunkPlace() and ChunkTerrainManager then
				-- SECOND-PLACE ONLY: generate the CENTER chunk now (synchronous,
				-- one plot's worth) so the player has ground to spawn on. The
				-- surrounding ring is generated AFTER the spawn teleport (see
				-- PlayerAdded) so the ring's attribute-swap can't race the teleport
				-- and drop the player into the void.
				ChunkTerrainManager.GenerateCenterChunk(buildArea, plotNumber)
				buildArea:SetAttribute("TerrainStyle", "Chunk")
				buildArea:SetAttribute("CurrentBiome", defaultBiome)
			else
				TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, defaultBiome, defaultTerrainStyle)
				buildArea:SetAttribute("TerrainStyle", defaultTerrainStyle)
				buildArea:SetAttribute("CurrentBiome", defaultBiome)
			end
			PlotTerrainReady[plotNumber] = true
		end

		-- NOTE: the paired NETHER bubble is intentionally NOT generated here. It used
		-- to generate eagerly in a task.spawn, but that caused two problems on the live
		-- server (not seen in Studio because Studio has instant/empty DataStore):
		--   1. Wasted work + double generation. If the player has a nether save,
		--      restoreNetherSave (during auto-load) wipes this random-seed cave and
		--      regenerates from the saved seed -- ~6s of generation thrown away.
		--   2. The heavy ~95k-block walk competed with the background terrain loop
		--      that drives the "N/9 loaded" bar, stalling it at 1/9 for seconds.
		-- Instead, nether generation is deferred to AFTER auto-load resolves (below),
		-- and only runs if the load didn't already generate it. See the auto-load
		-- task.spawn for the deferred, guarded generation.
	end
	
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
	
	-- Try to auto-load saved plot data, THEN generate the nether (deferred).
	task.spawn(function()
		-- SECOND-PLACE: NEVER load main-game plot saves onto the chunk world, and skip
		-- nether priming (no nether plots exist here). Shared DataStores mean loading
		-- would drop the player's real build onto the chunk plot and a save would
		-- overwrite it. The chunk world is self-generated; skip persistence entirely.
		if isChunkPlace() then
			print("[BB-CHUNK] skipping plot auto-load on chunk place")
			return
		end
		-- Wait for SaveManager to create the AutoLoadPlot BindableFunction (up to 10 seconds)
		local AutoLoadPlot = ReplicatedStorage:WaitForChild("AutoLoadPlot", 10)
		if AutoLoadPlot then
			local success, result = AutoLoadPlot:Invoke(player, buildArea, plotNumber)
			if success then
			else
			end
		else
			warn("[PlotManager] AutoLoadPlot not found after 10s timeout - SaveManager may have failed to initialize")
		end

		-- DEFERRED NETHER SEED PRIMING (no longer a full cave walk).
		-- We used to build the ENTIRE exposed surface of the bubble here, which meant
		-- the whole 128-tall sealed shell (the "walls") spawned up-front -- thousands
		-- of blocks the player never sees until they travel. Now we only PRIME THE
		-- SEED so the oracle is live; the actual visible cave is seeded as a small
		-- bounded region around the portal when the player first travels (see
		-- NetherTravelManager.buildReturnPortal), and the dig-reveal path streams the
		-- rest as they dig. If the player had a nether save, restoreNetherSave already
		-- handled seed + regen, so we skip priming entirely.
		--
		-- We still wait for AllPlotsReady before touching the nether so nothing
		-- competes with the "N/9 loaded" bar.
		local netherPlot = getNetherPlot(plotNumber)
		if netherPlot and TerrainGenerator then
			local netherKey = plotNumber + 100
			if TerrainGenerator.IsPlotGenerated and TerrainGenerator.IsPlotGenerated(netherKey) then
				print("[PlotManager] Nether already restored from save for plot " .. plotNumber .. " -- skipping seed priming")
			else
				local readyValue = ReplicatedStorage:FindFirstChild("AllPlotsReady")
				if readyValue and not readyValue.Value then
					local waitStart = tick()
					while not readyValue.Value and (tick() - waitStart) < 30 do
						task.wait(0.25)
					end
				end
				-- Re-check after waiting (a save-load could have run meanwhile).
				if not (TerrainGenerator.IsPlotGenerated and TerrainGenerator.IsPlotGenerated(netherKey)) then
					if ensureNetherPlotAttributes(netherPlot) then
						local netherBlocks = netherPlot:FindFirstChild("Blocks")
						if not netherBlocks then
							netherBlocks = Instance.new("Folder")
							netherBlocks.Name = "Blocks"
							netherBlocks.Parent = netherPlot
						end
						-- Just set the seed (cheap). No geometry built here. The portal
						-- build seeds the first visible region; digging reveals the rest.
						if not netherPlot:GetAttribute("NetherSeed") then
							netherPlot:SetAttribute("NetherSeed", math.random(1, 10000))
						end
						print("[PlotManager] Primed nether seed for plot " .. plotNumber .. " (cave streams on travel/dig)")
					end
				end
			end
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
		-- SECOND-PLACE: the chunk world is ephemeral and self-generating. Do NOT run the
		-- main-game clear/regenerate here. A 3x3 chunk plot is thousands of blocks; mass-
		-- clearing it on leave storms the per-block handlers (FallingBlockHandler's
		-- checkColumnAbove gets deferred per removal -> "script timeout"), and regenerating
		-- flat terrain over chunk terrain is meaningless. Just drop ownership + streaming.
		if isChunkPlace() then
			buildArea:SetAttribute("OwnerUserId", nil)
			buildArea:SetAttribute("OwnerName", nil)
			if buildArea:IsA("Model") then
				pcall(function() buildArea:RemovePersistentPlayer(player) end)
			end
			PlotOwners[plotNumber] = nil
			PlayerPlots[player] = nil
			return
		end

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
		
		-- Free-build chunk world: the terrain is shared, procedural, and never saved.
		-- Do not tear it down on player-leave. It is not a per-player plot, and destroying
		-- the entire terrain synchronously here is what freezes the server at shutdown
		-- (the silent hang right after Disconnect). Real plot worlds still clear normally.
		if not isChunkPlace() then
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
				
				TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, defaultBiome, defaultTerrainStyle)
				
				buildArea:SetAttribute("TerrainStyle", defaultTerrainStyle)
				buildArea:SetAttribute("CurrentBiome", defaultBiome)
				PlotTerrainReady[plotNumber] = true
			end)
		else
			PlotTerrainReady[plotNumber] = false
		end
	end
	
	PlotOwners[plotNumber] = nil
	PlayerPlots[player] = nil
end

local function teleportToPlot(player)
	-- Skip teleport if MegaPlot mode is active - MegaPlotVisibility handles spawning
	if isMegaPlotMode() then
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

-- ============================================
-- SHARED FREE-BUILD WORLD (second place only)
-- ============================================
-- ONE shared world per server: a single container at world origin that every
-- player occupies. No per-player plots. Created lazily on first join; the spawn
-- chunk (0,0) is generated once (sets ChunkCenterReady for the loading screen),
-- then ChunkStreamManager streams the rest around the UNION of all players.
local SHARED_WORLD_PLOT = 1 -- the synthetic container reuses BuildArea1 / plot id 1
local sharedWorldContainer = nil
local sharedWorldReady = false

local function ensureSharedWorld()
	if sharedWorldContainer and sharedWorldContainer.Parent then
		return sharedWorldContainer
	end
	if not (ChunkTerrainManager and ChunkTerrainManager.EnsureCenterBuildArea) then
		warn("[BB-CHUNK] ChunkTerrainManager missing; cannot build shared world")
		return nil
	end

	local container = ChunkTerrainManager.EnsureCenterBuildArea(SHARED_WORLD_PLOT)
	if not container then return nil end
	sharedWorldContainer = container

	-- Ensure a Blocks folder exists (player builds + spawn chunk live here, shared).
	if not container:FindFirstChild("Blocks") then
		local blocks = Instance.new("Folder")
		blocks.Name = "Blocks"
		blocks.Parent = container
	end

	-- Keep the shared world always loaded on every client (it's the whole map).
	if container:IsA("Model") then
		pcall(function() container.ModelStreamingMode = Enum.ModelStreamingMode.Atomic end)
	end

	-- Generate the spawn chunk (0,0) once. This sets ChunkCenterReady = true (the
	-- loading screen watches it) and gives ground at the origin to land on.
	if not sharedWorldReady and TerrainGenerator and ChunkTerrainManager.GenerateCenterChunk then
		ChunkTerrainManager.GenerateCenterChunk(container, SHARED_WORLD_PLOT)
		sharedWorldReady = true
	end

	-- Start the single shared-world streaming loop (idempotent).
	if ChunkStreamManager and ChunkStreamManager.StartStreaming then
		ChunkStreamManager.StartStreaming(container)
	end

	return container
end

-- Teleport a player onto the shared spawn chunk, with a small scatter so multiple
-- players don't stack on the exact same point at the origin.
local function teleportToSharedSpawn(player)
	local container = sharedWorldContainer
	if not container then return end
	local character = player.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local posX = container:GetAttribute("BasePlatePositionX") or 0
	local posZ = container:GetAttribute("BasePlatePositionZ") or 0
	local plateTop = container:GetAttribute("BasePlateTop")
	if not plateTop then
		local posY = container:GetAttribute("BasePlatePositionY") or 0
		local sizeY = container:GetAttribute("BasePlateSizeY") or 0
		plateTop = posY + sizeY / 2
	end

	-- Scatter within ~half a chunk so players don't spawn inside each other.
	local scatter = (GridConfig.BLOCK_SIZE or 3) * 4
	local offX = (math.random() * 2 - 1) * scatter
	local offZ = (math.random() * 2 - 1) * scatter
	local spawnPos = Vector3.new(posX + offX, plateTop + 5, posZ + offZ)

	local humanoid = character:FindFirstChild("Humanoid")
	if humanoid and humanoid.Sit then
		humanoid.Sit = false
		task.wait(0.1)
	end

	hrp.Anchored = true
	local forceField = character:FindFirstChild("TeleportProtection")
	if not forceField then
		forceField = Instance.new("ForceField")
		forceField.Name = "TeleportProtection"
		forceField.Visible = false
		forceField.Parent = character
	end

	character:PivotTo(CFrame.new(spawnPos))

	task.delay(0.3, function()
		if hrp and hrp.Parent then hrp.Anchored = false end
		if forceField and forceField.Parent then
			task.delay(0.5, function()
				if forceField and forceField.Parent then forceField:Destroy() end
			end)
		end
	end)
end

-- Free-build join: spawn into the ONE shared world. No plot assignment.
local function onFreeBuildPlayerAdded(player)
	ensureSharedWorld()

	local function handleCharacter(character)
		if isMegaPlotMode() then return end
		local hrp = character:WaitForChild("HumanoidRootPart", 5)
		if not hrp then return end
		hrp.Anchored = true
		task.wait(0.1)
		ensureSharedWorld() -- safe/idempotent; guarantees container exists
		teleportToSharedSpawn(player)
	end

	player.CharacterAdded:Connect(handleCharacter)
	if player.Character then
		task.spawn(handleCharacter, player.Character)
	end
end

Players.PlayerAdded:Connect(function(player)
	-- SECOND-PLACE: one shared world, no per-player plots.
	if isChunkPlace() then
		onFreeBuildPlayerAdded(player)
		return
	end

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

				-- SECOND-PLACE ONLY: player is now on the center chunk, so it's
				-- safe to fill the surrounding ring (idempotent; no-op on respawn).
				if isChunkPlace() and ChunkTerrainManager then
					local ba = getBuildArea(plotNumber)
					if ba then ChunkTerrainManager.GenerateRing(ba, plotNumber) end
				end
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

				-- SECOND-PLACE ONLY: ring after spawn (see note in CharacterAdded).
				if isChunkPlace() and ChunkTerrainManager then
					local ba = getBuildArea(plotNumber)
					if ba then ChunkTerrainManager.GenerateRing(ba, plotNumber) end
				end
			end
		end
	else
		warn("No plots available for " .. player.Name)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	
	-- SECOND-PLACE: do NOT save on the chunk world. It shares the public universe's
	-- DataStores; saving the chunk-terrain plot would overwrite the player's real
	-- main-game build. Just do in-memory cleanup (free the plot) and bail.
	if isChunkPlace() then
		print("[BB-CHUNK] skipping plot save on chunk place")
		releasePlot(player)
		return
	end
	
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
		else
			warn(string.format("[PlotManager] SavePlotSync FAILED for %s after %.2fs: %s", player.Name, saveTime, tostring(err)))
		end
	else
		warn("[PlotManager] SavePlotSync BindableFunction NOT FOUND - player data will NOT be saved!")
	end
	
	releasePlot(player)
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
			
		end

		-- Paired NETHER plot: hide the visible baseplate, mirroring the overworld
		-- (which DESTROYS its baseplate child). Each NetherPlot{N} is a single bare
		-- Part in the workspace -- it IS the baseplate, not a container with one. So
		-- we can't destroy it (it parents the cave Blocks folder and anchors the grid
		-- via getNetherPlot/getNetherFrame). Instead we cache its attributes FIRST
		-- (getNetherFrame reads those, never the part's live geometry) then make it
		-- invisible + non-collidable + non-query, so it disappears visually while
		-- staying as the plot's container. The cave's own bottom shell is the floor.
		local netherPlot = getNetherPlot(i)
		if netherPlot then
			ensureNetherPlotAttributes(netherPlot)
			if netherPlot:IsA("BasePart") then
				netherPlot.Transparency = 1
				netherPlot.CanCollide = false
				netherPlot.CanQuery = false   -- not selectable/targetable for building
				netherPlot.CanTouch = false
				netherPlot.CastShadow = false
			end
			local netherBlocks = netherPlot:FindFirstChild("Blocks")
			if not netherBlocks then
				netherBlocks = Instance.new("Folder")
				netherBlocks.Name = "Blocks"
				netherBlocks.Parent = netherPlot
			end
		end
	end
	
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
		-- Brief delay to let the first player's plot start generating. Kept short so the
		-- "N/9 loaded" bar doesn't visibly stall at 1/9 -- on the live server the first
		-- player's plot load (DataStore fetch + block placement) is heavy and competes
		-- for the scheduler, which used to stretch a 3s wait into a multi-second freeze.
		task.wait(0.5)
		
		local BiomeConfig = nil
		pcall(function()
			BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
		end)
		local defaultBiome = BiomeConfig and BiomeConfig.DefaultBiome or "Plains"
		local defaultTerrainStyle = "Flat"
		
		
		for i = 1, GridConfig.TOTAL_PLOTS do
			-- Skip plots that already have terrain (claimed by a player)
			if not PlotTerrainReady[i] then
				local buildArea = getBuildArea(i)
				if buildArea and TerrainGenerator then
					if isChunkPlace() then
						-- SECOND-PLACE ONLY: do NOT pre-fill unclaimed plots with flat
						-- terrain. The free-range chunk world is generated per-player on
						-- claim (GenerateCenterChunk + GenerateRing). Just mark the plot
						-- ready so the loading bar completes and AllPlotsReady flips.
						PlotTerrainReady[i] = true
					else
						TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, i, defaultBiome, defaultTerrainStyle)
						buildArea:SetAttribute("TerrainStyle", defaultTerrainStyle)
						buildArea:SetAttribute("CurrentBiome", defaultBiome)
						PlotTerrainReady[i] = true
					end

					-- Send progress to all clients showing loading screen
					local readyCount = 0
					for j = 1, GridConfig.TOTAL_PLOTS do
						if PlotTerrainReady[j] then readyCount = readyCount + 1 end
					end
					PlotsReady:FireAllClients("progress", readyCount, GridConfig.TOTAL_PLOTS)

					-- Brief yield between plots to spread out replication load without
					-- making the loading bar crawl. On the chunk place this is a near
					-- no-op (we only set the flag), so the bar completes promptly.
					task.wait(0.15)
				end
			end
		end

		-- Signal all clients that plots are ready
		allPlotsReadyValue.Value = true
		PlotsReady:FireAllClients("ready")
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
