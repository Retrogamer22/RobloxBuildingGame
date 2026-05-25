--[[
	PlotSignHandler (Server)
	Handles biome sign clicks, plot regeneration, and environment settings
	
	PREMIUM SYSTEM:
	- Free: Any biome, Flat terrain only
	- Premium: Natural terrain, Weather, Seasons
	
	Premium access is granted if:
	- Player is the owner
	- Currently in beta mode (everyone gets premium free)
	- Player is a registered beta tester (keeps premium after beta)
	- Player owns the gamepass
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))

-- ============================================
-- BETA PLAYER MANAGER (handles all premium checks)
-- ============================================
local BetaPlayerManager = nil
task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		local betaModule = modulesFolder:WaitForChild("BetaPlayerManager", 10)
		if betaModule then
			BetaPlayerManager = require(betaModule)
			print("[PlotSignHandler] BetaPlayerManager loaded")
		end
	end
end)

local function playerHasPremium(player)
	-- Use BetaPlayerManager if available
	if BetaPlayerManager then
		return BetaPlayerManager.HasPremiumAccess(player)
	end
	
	-- Fallback: owner always has premium
	return player.UserId == game.CreatorId
end

-- Modules
local TerrainGenerator = nil
local TreeGenerator = nil
local WeatherManager = nil
local SeasonManager = nil

task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		TerrainGenerator = require(modulesFolder:WaitForChild("TerrainGenerator", 10))
		TreeGenerator = require(modulesFolder:WaitForChild("TreeGenerator", 10))
		
		local weatherModule = modulesFolder:WaitForChild("WeatherManager", 5)
		if weatherModule then
			WeatherManager = require(weatherModule)
			print("[PlotSignHandler] WeatherManager loaded")
		end
		
		local seasonModule = modulesFolder:WaitForChild("SeasonManager", 5)
		if seasonModule then
			SeasonManager = require(seasonModule)
			print("[PlotSignHandler] SeasonManager loaded")
		end
	end
end)

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

local OpenBiomeUI = Instance.new("RemoteEvent")
OpenBiomeUI.Name = "OpenBiomeUI"
OpenBiomeUI.Parent = Remotes

local SelectBiome = Instance.new("RemoteEvent")
SelectBiome.Name = "SelectBiome"
SelectBiome.Parent = Remotes

local ApplyBiomeColors = Instance.new("RemoteEvent")
ApplyBiomeColors.Name = "ApplyBiomeColors"
ApplyBiomeColors.Parent = Remotes

local UpdatePlotEnvironment = Instance.new("RemoteEvent")
UpdatePlotEnvironment.Name = "UpdatePlotEnvironment"
UpdatePlotEnvironment.Parent = Remotes

local function getPlayerBuildArea(player)
	-- Check MegaPlot mode first
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	if modeValue and modeValue.Value == "MegaPlot" then
		local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
		if megaPlotRoom then
			local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
			if megaBuildArea then
				return megaBuildArea, 0
			end
		end
	end
	-- Individual plots
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea and buildArea:GetAttribute("OwnerUserId") == player.UserId then
			return buildArea, i
		end
	end
	return nil, nil
end

local function plotHasBlocks(buildArea)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return false end
	return #blocksFolder:GetChildren() > 0
end

local function applyEnvironment(buildArea, plotNumber, weather, season)
	if WeatherManager then
		WeatherManager.SetWeather(buildArea, plotNumber, weather or "Clear")
	end
	
	if SeasonManager then
		SeasonManager.SetSeason(buildArea, plotNumber, season or "Summer")
	end
end

-- Apply biome colors to existing blocks without regenerating terrain
local function applyBiomeColorsToPlot(buildArea, biomeName, seasonName)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return 0 end
	
	local biomeColors = BiomeConfig.GetBiomeColors(biomeName)
	if not biomeColors then return 0 end
	
	local blocksRecolored = 0
	seasonName = seasonName or "Summer"
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockType = block:GetAttribute("BlockType")
		
		-- Recolor grass blocks
		if blockType == "GrassBlock" or blockType == "SnowGrassBlock" or blockType == "TaigaGrassBlock" then
			if biomeColors.GrassColor then
				local grassColor = BiomeConfig.GetRandomizedGrassColor(biomeColors.GrassColor, seasonName)
				
				if block:IsA("Model") then
					local grassPart = block:FindFirstChild("Grass")
					if grassPart and grassPart:IsA("BasePart") then
						grassPart.Color = grassColor
					end
				elseif block:IsA("BasePart") then
					block.Color = grassColor
				end
				
				block:SetAttribute("Biome", biomeName)
				block:SetAttribute("Season", seasonName)
				blocksRecolored = blocksRecolored + 1
			end
		end
		
		-- Recolor grass decorations (ShortGrass, TallGrass)
		if blockType == "ShortGrass" or blockType == "TallGrass" then
			if biomeColors.GrassColor then
				local grassColor = BiomeConfig.GetRandomizedGrassColor(biomeColors.GrassColor, seasonName)
				
				if block:IsA("BasePart") then
					block.Color = grassColor
				elseif block:IsA("Model") then
					for _, part in ipairs(block:GetDescendants()) do
						if part:IsA("BasePart") then
							part.Color = grassColor
						end
					end
				end
				
				block:SetAttribute("Season", seasonName)
				blocksRecolored = blocksRecolored + 1
			end
		end
		
		-- Recolor leaves
		if blockType == "Leaves" or blockType == "OakLeaves" or blockType == "BirchLeaves" or blockType == "SpruceLeaves" then
			local treeType = block:GetAttribute("TreeType") or "Oak"
			local leafColor = BiomeConfig.GetRandomizedTintedLeafColor(treeType, biomeName, seasonName)
			
			if block:IsA("BasePart") then
				block.Color = leafColor
			elseif block:IsA("Model") then
				for _, part in ipairs(block:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Color = leafColor
					end
				end
			end
			
			block:SetAttribute("Biome", biomeName)
			block:SetAttribute("Season", seasonName)
			blocksRecolored = blocksRecolored + 1
		end
	end
	
	-- Update biome attribute on build area
	buildArea:SetAttribute("CurrentBiome", biomeName)
	buildArea:SetAttribute("CurrentSeason", seasonName)
	
	return blocksRecolored
end

local function setupSigns()
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local biomeSign = buildArea:FindFirstChild("BiomeSign")
			if biomeSign then
				local clickPart = biomeSign:FindFirstChild("ClickPart")
				if clickPart then
					local detector = clickPart:FindFirstChild("ClickDetector")
					if not detector then
						detector = Instance.new("ClickDetector")
						detector.MaxActivationDistance = 10
						detector.Parent = clickPart
					end
					
					detector.RightMouseClick:Connect(function(player)
						local ownerUserId = buildArea:GetAttribute("OwnerUserId")
						if ownerUserId == player.UserId then
							local hasBlocks = plotHasBlocks(buildArea)
							local currentWeather = buildArea:GetAttribute("CurrentWeather") or "Clear"
							local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
							local currentTerrainStyle = buildArea:GetAttribute("TerrainStyle") or "Flat"
							
							print(string.format("[PlotSignHandler] Opening BiomeUI for plot %d: TerrainStyle=%s, Biome=%s",
								i, currentTerrainStyle, buildArea:GetAttribute("CurrentBiome") or "None"))
							
							OpenBiomeUI:FireClient(
								player, 
								i, 
								buildArea:GetAttribute("CurrentBiome") or "None", 
								hasBlocks,
								currentWeather,
								currentSeason,
								currentTerrainStyle
							)
						end
					end)
					
					print("[PlotSignHandler] Sign setup for plot " .. i)
				end
			end
		end
	end
end

-- Get PlotClearing remote for notifying clients to clear particles
local PlotClearing = Remotes:FindFirstChild("PlotClearing")
if not PlotClearing then
	PlotClearing = Instance.new("RemoteEvent")
	PlotClearing.Name = "PlotClearing"
	PlotClearing.Parent = Remotes
end

local function generateWithBiome(buildArea, plotNumber, biomeName, terrainStyle, seed, weather, season, preferredBiomes)
	if not TerrainGenerator then
		warn("[PlotSignHandler] TerrainGenerator not loaded!")
		return
	end
	
	-- Default mode doesn't need a specific biome validation (it picks its own)
	if terrainStyle ~= "Default" then
		local biomeConfig = BiomeConfig.GetBiome(biomeName)
		if not biomeConfig then
			warn("[PlotSignHandler] Unknown biome: " .. biomeName)
			return
		end
	end
	
	-- Notify clients to clear particles (leaf particles, etc.) before terrain is destroyed
	local ownerUserId = buildArea:GetAttribute("OwnerUserId")
	if ownerUserId then
		local owner = game:GetService("Players"):GetPlayerByUserId(ownerUserId)
		if owner then
			PlotClearing:FireClient(owner, plotNumber)
		end
	end
	
	buildArea:SetAttribute("CurrentBiome", biomeName)
	buildArea:SetAttribute("TerrainStyle", terrainStyle)
	if seed then
		buildArea:SetAttribute("TerrainSeed", seed)
	end
	
	TerrainGenerator.ClearAllBlocks(buildArea, plotNumber)
	TerrainGenerator.ResetPlot(plotNumber)
	
	local blocksCreated
	if terrainStyle == "Default" then
		-- Multi-biome world generation with optional preferred biomes
		blocksCreated = TerrainGenerator.GenerateDefaultTerrain(buildArea, plotNumber, seed, preferredBiomes)
	elseif terrainStyle == "Biome" or terrainStyle == "Natural" then
		-- Single specific biome with natural terrain
		blocksCreated = TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, biomeName, "Natural", seed)
	else
		-- Flat terrain
		blocksCreated = TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, biomeName, "Flat", seed)
	end
	
	-- Remove baseplate after terrain is generated (if it still exists)
	local basePlate = buildArea:FindFirstChild("BasePlate")
	if basePlate then
		basePlate:Destroy()
		print("[PlotSignHandler] Baseplate removed for plot " .. plotNumber)
	end
	
	-- Apply environment after terrain
	applyEnvironment(buildArea, plotNumber, weather, season)
	
	print("[PlotSignHandler] Generated " .. biomeName .. " with weather: " .. (weather or "Clear") .. ", season: " .. (season or "Summer"))
end

-- Handle biome selection
SelectBiome.OnServerEvent:Connect(function(player, biomeName, terrainStyle, seed, weather, season, preferredBiomes)
	local buildArea, plotNumber = getPlayerBuildArea(player)
	if not buildArea then
		warn("[PlotSignHandler] Player doesn't own a plot!")
		return
	end
	
	-- For Default terrain, biomeName may be "Default" (no specific biome needed)
	if terrainStyle ~= "Default" and not BiomeConfig.Biomes[biomeName] then
		warn("[PlotSignHandler] Invalid biome: " .. biomeName)
		return
	end
	
	-- Check premium status for Natural terrain
	local hasPremium = playerHasPremium(player)
	
	-- Default and Biome (Natural) terrain require premium
	if (terrainStyle == "Natural" or terrainStyle == "Default" or terrainStyle == "Biome") and not hasPremium then
		warn("[PlotSignHandler] " .. player.Name .. " tried to use " .. terrainStyle .. " terrain without premium!")
		terrainStyle = "Flat"  -- Force flat for non-premium
	end
	
	terrainStyle = terrainStyle or "Flat"
	
	-- Weather and seasons require premium
	if not hasPremium then
		weather = "Clear"
		season = "Summer"
	else
		weather = weather or "Clear"
		season = season or "Summer"
	end
	
	if seed then
		seed = tonumber(seed)
		if not seed or seed <= 0 then seed = nil end
	end
	
	-- Validate preferredBiomes (table of biome name strings)
	if preferredBiomes and type(preferredBiomes) == "table" then
		local validated = {}
		for _, name in ipairs(preferredBiomes) do
			if type(name) == "string" and BiomeConfig.BiomeTemperatures[name] then
				table.insert(validated, name)
			end
		end
		preferredBiomes = #validated > 0 and validated or nil
	else
		preferredBiomes = nil
	end
	
	print(string.format(
		"[PlotSignHandler] %s: Biome=%s, Terrain=%s, Weather=%s, Season=%s, Preferred=%s (Premium: %s)",
		player.Name, biomeName, terrainStyle, weather, season, 
		preferredBiomes and table.concat(preferredBiomes, ",") or "none",
		tostring(hasPremium)
	))
	
	generateWithBiome(buildArea, plotNumber, biomeName, terrainStyle, seed, weather, season, preferredBiomes)
end)

-- Handle environment-only update (premium only)
UpdatePlotEnvironment.OnServerEvent:Connect(function(player, weather, season)
	local buildArea, plotNumber = getPlayerBuildArea(player)
	if not buildArea then
		warn("[PlotSignHandler] Player doesn't own a plot!")
		return
	end
	
	-- Check premium status
	if not playerHasPremium(player) then
		warn("[PlotSignHandler] " .. player.Name .. " tried to change environment without premium!")
		return  -- Don't allow environment changes without premium
	end
	
	weather = weather or "Clear"
	season = season or "Summer"
	
	print(string.format("[PlotSignHandler] %s updating environment: Weather=%s, Season=%s", player.Name, weather, season))
	
	applyEnvironment(buildArea, plotNumber, weather, season)
end)

-- Handle apply biome colors only (no regeneration, free for everyone)
ApplyBiomeColors.OnServerEvent:Connect(function(player, biomeName, season)
	local buildArea, plotNumber = getPlayerBuildArea(player)
	if not buildArea then
		warn("[PlotSignHandler] Player doesn't own a plot!")
		return
	end
	
	if not BiomeConfig.Biomes[biomeName] then
		warn("[PlotSignHandler] Invalid biome: " .. biomeName)
		return
	end
	
	season = season or buildArea:GetAttribute("CurrentSeason") or "Summer"
	
	local blocksRecolored = applyBiomeColorsToPlot(buildArea, biomeName, season)
	
	print(string.format("[PlotSignHandler] %s applied %s colors to %d blocks", player.Name, biomeName, blocksRecolored))
end)

task.spawn(function()
	task.wait(2)
	setupSigns()
end)

print("[PlotSignHandler] Initialized")
