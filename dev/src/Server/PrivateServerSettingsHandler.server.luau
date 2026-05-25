--[[
	PrivateServerSettingsHandler (Server)
	Handles ApplyPrivateServerSettings remote from owner
	
	Applies settings to all plots or mega-plot:
	- Mode changes (with terrain reset)
	- Biome changes
	- Terrain style changes
	- Weather/Season changes
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

print("[PrivateServerSettingsHandler] Script starting...")

-- Wait for private server system
local isPrivateServerValue = ReplicatedStorage:WaitForChild("IsPrivateServer", 15)
print("[PrivateServerSettingsHandler] IsPrivateServer value:", isPrivateServerValue and isPrivateServerValue.Value)

if not isPrivateServerValue then
	warn("[PrivateServerSettingsHandler] IsPrivateServer not found after 15s!")
	return
end

-- Wait for the value to become true (debug mode might set it after creation)
if not isPrivateServerValue.Value then
	print("[PrivateServerSettingsHandler] Waiting for IsPrivateServer to become true...")
	local waitStart = tick()
	while not isPrivateServerValue.Value and (tick() - waitStart) < 10 do
		task.wait(0.1)
	end
	
	if not isPrivateServerValue.Value then
		print("[PrivateServerSettingsHandler] Not a private server, handler disabled")
		return
	end
end

print("[PrivateServerSettingsHandler] Private server confirmed, loading handler...")

local ownerIdValue = ReplicatedStorage:WaitForChild("PrivateServerOwnerId", 10)
local modeValue = ReplicatedStorage:WaitForChild("PrivateServerMode", 10)

-- Load modules
local Modules = ServerScriptService:WaitForChild("Modules", 10)
local PrivateServerManager = require(Modules:WaitForChild("PrivateServerManager"))
local TerrainGenerator = require(Modules:WaitForChild("TerrainGenerator"))

-- Get/create remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

local ApplyPrivateServerSettings = Remotes:FindFirstChild("ApplyPrivateServerSettings")
if not ApplyPrivateServerSettings then
	ApplyPrivateServerSettings = Instance.new("RemoteEvent")
	ApplyPrivateServerSettings.Name = "ApplyPrivateServerSettings"
	ApplyPrivateServerSettings.Parent = Remotes
end

local ApplyBiomeColors = Remotes:FindFirstChild("ApplyBiomeColors")

-- Lightweight remote for instant cosmetic updates (biome/season/weather)
local UpdateCosmetics = Remotes:FindFirstChild("UpdateCosmetics")
if not UpdateCosmetics then
	UpdateCosmetics = Instance.new("RemoteEvent")
	UpdateCosmetics.Name = "UpdateCosmetics"
	UpdateCosmetics.Parent = Remotes
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function isOwner(player)
	return ownerIdValue and ownerIdValue.Value == player.UserId
end

local function getAllBuildAreas()
	local areas = {}
	local workspace = game:GetService("Workspace")
	
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj.Name:match("^BuildArea%d+$") then
			table.insert(areas, obj)
		end
	end
	
	-- Sort by plot number
	table.sort(areas, function(a, b)
		local numA = tonumber(a.Name:match("BuildArea(%d+)")) or 0
		local numB = tonumber(b.Name:match("BuildArea(%d+)")) or 0
		return numA < numB
	end)
	
	return areas
end

local function clearAndRegeneratePlot(buildArea, plotNumber, biome, terrainStyle, season, seed)
	print("[PrivateServerSettingsHandler] Clearing plot", plotNumber)
	
	-- Clear all blocks
	TerrainGenerator.ClearAllBlocks(buildArea, plotNumber)
	
	-- Reset the plot tracking
	TerrainGenerator.ResetPlot(plotNumber)
	
	-- Set the season attribute before generation
	buildArea:SetAttribute("CurrentSeason", season or "Summer")
	buildArea:SetAttribute("CurrentBiome", biome or "Plains")
	buildArea:SetAttribute("TerrainStyle", terrainStyle or "Flat")
	
	-- Wait a frame for cleanup
	task.wait()
	
	-- Route to correct generator based on terrain style
	print("[PrivateServerSettingsHandler] Regenerating plot", plotNumber, "with biome:", biome, "terrain:", terrainStyle)
	if terrainStyle == "Default" then
		-- Multi-biome world generation with optional seed
		TerrainGenerator.GenerateDefaultTerrain(buildArea, plotNumber, seed)
	elseif terrainStyle == "Biome" or terrainStyle == "Natural" then
		-- Single specific biome with natural terrain
		TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, biome or "Plains", "Natural", seed)
	else
		-- Flat terrain
		TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, biome or "Plains", "Flat", seed)
	end
end

local function getMegaPlotVisibility()
	-- Wait for MegaPlotVisibility to initialize
	local maxWait = 5
	local waited = 0
	while not _G.MegaPlotVisibility and waited < maxWait do
		task.wait(0.1)
		waited = waited + 0.1
	end
	return _G.MegaPlotVisibility
end

-- ============================================
-- PROCESSING FLAG (prevents duplicate concurrent calls)
-- ============================================
local isProcessing = false

-- ============================================
-- MAIN HANDLER
-- ============================================

ApplyPrivateServerSettings.OnServerEvent:Connect(function(player, settings)
	-- Prevent duplicate/concurrent calls
	if isProcessing then
		print("[PrivateServerSettingsHandler] Already processing, ignoring duplicate call")
		return
	end
	isProcessing = true
	
	print("[PrivateServerSettingsHandler] ========== RECEIVED SETTINGS ==========")
	
	-- Verify owner
	if not isOwner(player) then
		warn("[PrivateServerSettingsHandler] Non-owner tried to change settings:", player.Name)
		isProcessing = false
		return
	end
	
	print("[PrivateServerSettingsHandler] Owner", player.Name, "applying settings")
	print("  Mode:", settings.mode)
	print("  Biome:", settings.biome)
	print("  Terrain:", settings.terrainStyle)
	print("  Season:", settings.season)
	print("  Weather:", settings.weather)
	print("  ConfirmReset:", settings.confirmReset)
	
	-- Get terrain ready/progress values at handler scope (used to control loading screen)
	local terrainReadyValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainReady")
	local progressValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainProgress")
	
	local mode = settings.mode or "Individual"
	local biome = settings.biome or "Plains"
	local terrainStyle = settings.terrainStyle or "Flat"
	local season = settings.season or "Summer"
	local weather = settings.weather or "Clear"
	local confirmReset = settings.confirmReset
	
	-- Validate seed (optional numeric value from create page)
	local seed = nil
	if settings.seed and type(settings.seed) == "number" then
		seed = math.floor(settings.seed)
		if seed < 1 or seed > 9999999999 then seed = nil end
	end
	
	-- Handle "Keep Same Seed" from regenerate dialog
	-- newSeed == false means reuse existing seed, newSeed == true or nil means random
	if settings.newSeed == false then
		local existingSeed = nil
		-- Check MegaPlot build area first
		local megaPlotVisibility = getMegaPlotVisibility()
		if megaPlotVisibility and megaPlotVisibility.GetMegaPlotBuildArea then
			local megaBuildArea = megaPlotVisibility.GetMegaPlotBuildArea()
			if megaBuildArea then
				existingSeed = megaBuildArea:GetAttribute("TerrainSeed")
			end
		end
		-- Fallback to individual build areas
		if not existingSeed then
			local buildAreas = getAllBuildAreas()
			if #buildAreas > 0 then
				existingSeed = buildAreas[1]:GetAttribute("TerrainSeed")
			end
		end
		if existingSeed then
			seed = existingSeed
			print("  Reusing existing seed:", seed)
		end
	end
	print("  Seed:", seed or "random")
	
	-- Check if mode is changing
	local currentMode = PrivateServerManager.GetMode()
	local modeChanging = mode ~= currentMode
	
	-- Check if terrain style is changing (requires regeneration)
	local currentTerrainStyle = nil
	local buildAreas = getAllBuildAreas()
	if #buildAreas > 0 then
		currentTerrainStyle = buildAreas[1]:GetAttribute("TerrainStyle")
	end
	local terrainStyleChanging = currentTerrainStyle ~= nil and terrainStyle ~= currentTerrainStyle
	
	-- Either mode or terrain style change requires full regeneration
	-- Also force regeneration when RESET is confirmed (Create New World always regenerates)
	local needsRegeneration = modeChanging or terrainStyleChanging or confirmReset == "RESET"
	
	print("[PrivateServerSettingsHandler] Current mode:", currentMode, "| New mode:", mode, "| Changing:", modeChanging)
	print("[PrivateServerSettingsHandler] Current terrain:", currentTerrainStyle, "| New terrain:", terrainStyle, "| Changing:", terrainStyleChanging)
	print("[PrivateServerSettingsHandler] Needs regeneration:", needsRegeneration)
	
	if needsRegeneration then
		-- Require RESET confirmation for destructive changes
		if confirmReset ~= "RESET" then
			warn("[PrivateServerSettingsHandler] Terrain regeneration requires RESET confirmation, got:", tostring(confirmReset))
			isProcessing = false
			return
		end
		
		-- IMMEDIATELY mark terrain as not ready so loading screen stays visible
		-- (Must happen BEFORE the save, which can take 25+ seconds)
		if terrainReadyValue then
			terrainReadyValue.Value = false
		end
		if progressValue then
			progressValue.Value = 0
		end
		
		-- Auto-save mega plot before switching away from MegaPlot mode
		-- ONLY save if we're actually switching modes (not just changing terrain style)
		-- Saving is slow for large plots and blocks terrain regeneration
		if modeChanging and currentMode == "MegaPlot" and _G.MegaPlotSaveManager then
			print("[PrivateServerSettingsHandler] Saving mega plot before mode switch...")
			local saveSuccess, saveResult = _G.MegaPlotSaveManager.Save()
			if saveSuccess then
				print("[PrivateServerSettingsHandler] Mega plot saved:", saveResult, "blocks")
			else
				warn("[PrivateServerSettingsHandler] Mega plot save failed:", saveResult)
			end
		elseif not modeChanging and currentMode == "MegaPlot" and _G.MegaPlotSaveManager then
			-- Creating new world / terrain regen - must save BEFORE clearing
			print("[PrivateServerSettingsHandler] Saving mega plot before terrain regen...")
			local saveSuccess, saveResult = _G.MegaPlotSaveManager.Save()
			if saveSuccess then
				print("[PrivateServerSettingsHandler] Save complete:", saveResult, "blocks")
			else
				warn("[PrivateServerSettingsHandler] Save failed:", saveResult)
			end
		end
		
		-- (terrainReadyValue already set to false above, before the save)
		
		-- Only update mode in DataStore if the mode is actually changing
		if modeChanging then
			print("[PrivateServerSettingsHandler] Mode changing from", currentMode, "to", mode)
			
			-- Update mode in PrivateServerManager (saves to DataStore)
			local success, err = PrivateServerManager.SetMode(mode, player)
			print("[PrivateServerSettingsHandler] SetMode result:", success, err)
			if not success then
				warn("[PrivateServerSettingsHandler] Failed to set mode:", err)
				isProcessing = false
				return
			end
			
			-- Update the shared value for clients (triggers MegaPlotVisibility.Changed)
			if modeValue then
				print("[PrivateServerSettingsHandler] Updating modeValue to:", mode)
				modeValue.Value = mode
			else
				warn("[PrivateServerSettingsHandler] modeValue not found!")
			end
		else
			print("[PrivateServerSettingsHandler] Terrain style change only, skipping mode DataStore save")
		end
	end
	
	-- Get MegaPlotVisibility module
	print("[PrivateServerSettingsHandler] Getting MegaPlotVisibility module...")
	local megaPlotVisibility = getMegaPlotVisibility()
	print("[PrivateServerSettingsHandler] MegaPlotVisibility:", megaPlotVisibility and "FOUND" or "NOT FOUND")
	
	-- Handle based on mode
	if mode == "MegaPlot" then
		-- === MEGA-PLOT MODE ===
		print("[PrivateServerSettingsHandler] ===== SETTING UP MEGAPLOT MODE =====")
		
		if megaPlotVisibility then
			if needsRegeneration then
				-- Full regeneration needed for mode switch or terrain style change
				print("[PrivateServerSettingsHandler] Full terrain regeneration needed")
				print("[PrivateServerSettingsHandler] MegaPlotRoom:", megaPlotVisibility.GetMegaPlotRoom() and "EXISTS" or "NOT FOUND")
				
				-- Show loading screen to all clients BEFORE clearing/regenerating
				if megaPlotVisibility.ShowLoadingScreenToAllClients then
					megaPlotVisibility.ShowLoadingScreenToAllClients("Regenerating terrain...")
				end
				
				-- Protect all players (anchor + forcefield) during terrain reset
				for _, plr in ipairs(Players:GetPlayers()) do
					local character = plr.Character
					if character then
						local hrp = character:FindFirstChild("HumanoidRootPart")
						if hrp then
							hrp.Anchored = true
							-- Move to safe position high up
							local spawnPos = megaPlotVisibility.GetSpawnPosition()
							if spawnPos then
								character:PivotTo(CFrame.new(spawnPos + Vector3.new(0, 50, 0)))
							end
							-- Add ForceField protection
							if not character:FindFirstChild("ResetProtection") then
								local ff = Instance.new("ForceField")
								ff.Name = "ResetProtection"
								ff.Visible = false
								ff.Parent = character
							end
						end
					end
				end
				
				task.wait(0.1) -- Brief moment for clients to show loading screen
				
				-- Auto-save all online players' individual plots before switching to MegaPlot
				if modeChanging then
					local SavePlotSync = ReplicatedStorage:FindFirstChild("SavePlotSync")
					if SavePlotSync then
						print("[PrivateServerSettingsHandler] Saving all individual plots before MegaPlot switch...")
						for _, plr in ipairs(Players:GetPlayers()) do
							local success, err = pcall(function()
								SavePlotSync:Invoke(plr)
							end)
							if success then
								print("[PrivateServerSettingsHandler] Saved individual plot for", plr.Name)
							else
								warn("[PrivateServerSettingsHandler] Failed to save plot for", plr.Name, ":", tostring(err))
							end
						end
						print("[PrivateServerSettingsHandler] All individual plots saved")
					else
						warn("[PrivateServerSettingsHandler] SavePlotSync not found - individual plots won't be saved!")
					end
				end
				
				megaPlotVisibility.ClearTerrain()
				task.wait(0.1) -- Brief moment for cleanup
				
				-- When switching TO MegaPlot mode, check for a saved world to auto-load
				local autoLoaded = false
				if modeChanging then
					local megaPlotSaveManager = _G.MegaPlotSaveManager
					if megaPlotSaveManager then
						print("[PrivateServerSettingsHandler] Checking for saved mega plot to auto-load...")
						local DataStoreService = game:GetService("DataStoreService")
						local serverId = PrivateServerManager.GetServerId()
						
						if serverId and serverId ~= "" then
							local slotDS = nil
							pcall(function() slotDS = DataStoreService:GetDataStore("MegaPlotSlots_v1") end)
							
							if slotDS then
								local metaKey = serverId .. "_slotmeta"
								local metaSuccess, metadata = pcall(function() return slotDS:GetAsync(metaKey) end)
								
								local slotNum = nil
								if metaSuccess and metadata and metadata.lastPlayedSlot then
									slotNum = metadata.lastPlayedSlot
									print("[PrivateServerSettingsHandler] Last played slot:", slotNum)
								else
									-- No lastPlayedSlot — default to slot 1
									slotNum = 1
									print("[PrivateServerSettingsHandler] No lastPlayedSlot, defaulting to slot 1")
								end
								
								if slotNum then
									local slotKey = serverId .. "_slot_" .. tostring(slotNum)
									print("[PrivateServerSettingsHandler] Loading from slot", slotNum, "...")
									
									local slotSuccess, slotData = pcall(function() return slotDS:GetAsync(slotKey) end)
									if slotSuccess and slotData and slotData.data then
										local buildArea = megaPlotVisibility.GetMegaPlotBuildArea()
										if buildArea then
											local loadOk, loadResult = megaPlotSaveManager.LoadFromData(slotData.data, buildArea)
											if loadOk then
												print("[PrivateServerSettingsHandler] Auto-loaded from slot", slotNum, ":", loadResult, "blocks")
												autoLoaded = true
												-- Set active slot so future auto-saves go here
												if megaPlotSaveManager.SetActiveSlot then
													megaPlotSaveManager.SetActiveSlot(slotNum)
												end
											else
												warn("[PrivateServerSettingsHandler] Auto-load failed:", loadResult)
											end
										else
											warn("[PrivateServerSettingsHandler] Build area not available for auto-load")
										end
									else
										print("[PrivateServerSettingsHandler] Slot", slotNum, "has no data")
									end
								else
									print("[PrivateServerSettingsHandler] No lastPlayedSlot in metadata")
								end
							end
						end
					end
				end
				
				-- Only generate fresh terrain if no saved world was loaded
				local buildArea
				if not autoLoaded then
					print("[PrivateServerSettingsHandler] Generating fresh terrain:", biome, terrainStyle, season)
					if terrainStyle == "Default" then
						buildArea = megaPlotVisibility.SetupTerrain(biome, "Default", season, seed)
					else
						local generatorStyle = (terrainStyle == "Biome") and "Natural" or terrainStyle
						buildArea = megaPlotVisibility.SetupTerrain(biome, generatorStyle, season, seed)
					end
					print("[PrivateServerSettingsHandler] SetupTerrain returned:", buildArea and buildArea.Name or "nil")
				else
					-- Auto-load handled terrain internally; mark terrain as ready
					-- so the loading screen dismisses
					if terrainReadyValue then
						terrainReadyValue.Value = true
					end
				end
			else
				-- No mode change - just update attributes and colors (preserve builds)
				print("[PrivateServerSettingsHandler] Updating MegaPlot settings without regeneration")
				local buildArea = megaPlotVisibility.GetMegaPlotBuildArea()
				if buildArea then
					buildArea:SetAttribute("CurrentBiome", biome)
					buildArea:SetAttribute("CurrentSeason", season)
					buildArea:SetAttribute("TerrainStyle", terrainStyle)
					
					-- Update grass block colors to match new biome
					TerrainGenerator.UpdateTerrainColors(buildArea, biome, season)
				else
					warn("[PrivateServerSettingsHandler] Could not find MegaPlot build area for settings update")
				end
			end
		else
			warn("[PrivateServerSettingsHandler] MegaPlotVisibility not available!")
		end
		
	else
		-- === INDIVIDUAL PLOTS MODE ===
		print("[PrivateServerSettingsHandler] Setting up Individual Plots mode...")
		
		if needsRegeneration then
			-- Full regeneration needed for mode switch or terrain style change
			print("[PrivateServerSettingsHandler] Full terrain regeneration needed")
			
			-- Show loading screen to all clients
			if megaPlotVisibility and megaPlotVisibility.ShowLoadingScreenToAllClients then
				megaPlotVisibility.ShowLoadingScreenToAllClients("Switching to Individual Plots...")
			end
			
			-- Protect all players during terrain reset
			for _, plr in ipairs(Players:GetPlayers()) do
				local character = plr.Character
				if character then
					local hrp = character:FindFirstChild("HumanoidRootPart")
					if hrp then
						hrp.Anchored = true
						if not character:FindFirstChild("ResetProtection") then
							local ff = Instance.new("ForceField")
							ff.Name = "ResetProtection"
							ff.Visible = false
							ff.Parent = character
						end
					end
				end
			end
			
			-- Clear MegaPlot terrain and hide the room if switching from MegaPlot mode
			if megaPlotVisibility and modeChanging then
				megaPlotVisibility.ClearTerrain()
				-- Hide the mega plot room now (loading screen is covering the transition)
				if megaPlotVisibility.HideMegaPlotRoom then
					megaPlotVisibility.HideMegaPlotRoom()
				end
			end
			
			task.wait(0.2)
			
			local buildAreas = getAllBuildAreas()
			if #buildAreas == 0 then
				warn("[PrivateServerSettingsHandler] No build areas found!")
				isProcessing = false
				return
			end
			
			print("[PrivateServerSettingsHandler] Found", #buildAreas, "build areas")
			
			-- Track plot completion for real progress reporting
			local totalPlots = #buildAreas
			local completedPlots = 0
			
			for _, buildArea in ipairs(buildAreas) do
				local plotNumber = tonumber(buildArea.Name:match("BuildArea(%d+)"))
				if plotNumber then
					task.spawn(function()
						clearAndRegeneratePlot(buildArea, plotNumber, biome, terrainStyle, season, seed)
						completedPlots = completedPlots + 1
						if progressValue then
							progressValue.Value = completedPlots / totalPlots
						end
					end)
					task.wait(0.1)
				end
			end
			
			-- Wait for ALL plots to finish generating
			local maxWait = 60
			local waited = 0
			while completedPlots < totalPlots and waited < maxWait do
				task.wait(0.2)
				waited = waited + 0.2
			end
			
			-- Auto-load each online player's saved build onto their individual plot
			local AutoLoadPlot = ReplicatedStorage:FindFirstChild("AutoLoadPlot")
			if AutoLoadPlot then
				print("[PrivateServerSettingsHandler] Auto-loading saved builds for all online players...")
				for _, plr in ipairs(Players:GetPlayers()) do
					task.spawn(function()
						-- Find the player's assigned build area
						for _, ba in ipairs(buildAreas) do
							if ba:GetAttribute("OwnerUserId") == plr.UserId then
								local plotNum = tonumber(ba.Name:match("BuildArea(%d+)"))
								if plotNum then
									local success, result = AutoLoadPlot:Invoke(plr, ba, plotNum)
									if success then
										print("[PrivateServerSettingsHandler] Auto-loaded save for", plr.Name)
									else
										print("[PrivateServerSettingsHandler] No save to load for", plr.Name, "(", tostring(result), ")")
									end
								end
								break
							end
						end
					end)
				end
				-- Give auto-loads a moment to complete before teleporting
				task.wait(1)
			else
				warn("[PrivateServerSettingsHandler] AutoLoadPlot not found - saves won't be restored")
			end
			
			-- Teleport each player to their assigned plot's PlayerSpawn
			for _, plr in ipairs(Players:GetPlayers()) do
				local character = plr.Character
				if not character then continue end
				local hrp = character:FindFirstChild("HumanoidRootPart")
				if not hrp then continue end
				
				-- Find the player's assigned build area by OwnerUserId attribute
				local targetSpawnPos = nil
				for _, ba in ipairs(buildAreas) do
					if ba:GetAttribute("OwnerUserId") == plr.UserId then
						local spawnPart = ba:FindFirstChild("PlayerSpawn")
						if spawnPart and spawnPart:IsA("BasePart") then
							targetSpawnPos = spawnPart.Position + Vector3.new(0, 3, 0)
						else
							-- Fallback to baseplate center
							local posX = ba:GetAttribute("BasePlatePositionX")
							local posY = ba:GetAttribute("BasePlatePositionY")
							local posZ = ba:GetAttribute("BasePlatePositionZ")
							local sizeY = ba:GetAttribute("BasePlateSizeY")
							if posX and posY and posZ and sizeY then
								targetSpawnPos = Vector3.new(posX, posY + sizeY / 2 + 5, posZ)
							end
						end
						break
					end
				end
				
				if targetSpawnPos then
					character:PivotTo(CFrame.new(targetSpawnPos))
					print("[PrivateServerSettingsHandler] Teleported", plr.Name, "to their plot spawn")
				end
				
				-- Unanchor and remove protection
				hrp.Anchored = false
				local ff = character:FindFirstChild("ResetProtection")
				if ff then ff:Destroy() end
			end
			
			-- Signal terrain ready so loading screen dismisses
			if terrainReadyValue then
				print("[PrivateServerSettingsHandler] Setting MegaPlotTerrainReady = true")
				terrainReadyValue.Value = true
			else
				warn("[PrivateServerSettingsHandler] MegaPlotTerrainReady not found!")
			end
		else
			-- No mode change - just update attributes and colors (preserve builds)
			print("[PrivateServerSettingsHandler] Updating plot settings without regeneration")
			
			local buildAreas = getAllBuildAreas()
			for _, buildArea in ipairs(buildAreas) do
				buildArea:SetAttribute("CurrentBiome", biome)
				buildArea:SetAttribute("CurrentSeason", season)
				buildArea:SetAttribute("TerrainStyle", terrainStyle)
				
				-- Update grass block colors to match new biome
				local plotNumber = tonumber(buildArea.Name:match("BuildArea(%d+)"))
				if plotNumber then
					TerrainGenerator.UpdateTerrainColors(buildArea, biome, season)
				end
			end
		end
	end
	
	-- Notify clients to update biome colors
	if ApplyBiomeColors then
		ApplyBiomeColors:FireAllClients(biome, season)
	end
	
	-- Mark first-time setup as complete
	if PrivateServerManager.IsFirstTimeSetup() then
		PrivateServerManager.MarkSetupComplete()
	end
	
	print("[PrivateServerSettingsHandler] Settings applied successfully!")
	isProcessing = false
end)

-- ============================================
-- INSTANT COSMETIC HANDLER (biome/season/weather)
-- No regeneration, just recolors existing blocks
-- ============================================
local lastCosmeticTime = 0
local COSMETIC_DEBOUNCE = 0.3

UpdateCosmetics.OnServerEvent:Connect(function(player, settings)
	local now = tick()
	if now - lastCosmeticTime < COSMETIC_DEBOUNCE then return end
	lastCosmeticTime = now
	
	if not isOwner(player) then
		warn("[PrivateServerSettingsHandler] Non-owner tried to update cosmetics:", player.Name)
		return
	end
	
	local biome = settings.biome
	local season = settings.season
	local weather = settings.weather
	
	print("[PrivateServerSettingsHandler] Instant cosmetic update - Biome:", biome, "Season:", season, "Weather:", weather)
	
	local currentMode = PrivateServerManager.GetMode()
	
	if currentMode == "MegaPlot" then
		local megaPlotVisibility = getMegaPlotVisibility()
		if megaPlotVisibility then
			local buildArea = megaPlotVisibility.GetMegaPlotBuildArea()
			if buildArea then
				if biome then buildArea:SetAttribute("CurrentBiome", biome) end
				if season then buildArea:SetAttribute("CurrentSeason", season) end
				TerrainGenerator.UpdateTerrainColors(buildArea, biome or buildArea:GetAttribute("CurrentBiome") or "Plains", season or buildArea:GetAttribute("CurrentSeason") or "Summer")
			else
				warn("[PrivateServerSettingsHandler] Could not find MegaPlot build area for cosmetic update")
			end
		end
	else
		local areas = getAllBuildAreas()
		for _, buildArea in ipairs(areas) do
			if biome then buildArea:SetAttribute("CurrentBiome", biome) end
			if season then buildArea:SetAttribute("CurrentSeason", season) end
			TerrainGenerator.UpdateTerrainColors(buildArea, biome or buildArea:GetAttribute("CurrentBiome") or "Plains", season or buildArea:GetAttribute("CurrentSeason") or "Summer")
		end
	end
	
	-- Notify clients
	if ApplyBiomeColors then
		ApplyBiomeColors:FireAllClients(biome, season)
	end
	
	print("[PrivateServerSettingsHandler] Cosmetic update complete")
end)

print("[PrivateServerSettingsHandler] Handler initialized")
