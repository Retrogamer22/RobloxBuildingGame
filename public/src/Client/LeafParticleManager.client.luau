-- LeafParticleManager.client.luau
-- Client-side script that handles ambient falling leaf particles
-- Uses simple square parts that fall with gentle swaying motion
-- Integrates with plot system and seasons
-- Adapted from Ashborne LeafParticleManager
-- Place in StarterPlayerScripts

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

-- Configuration
local CONFIG = {
	-- Base spawn settings (modified by season)
	BASE_SPAWN_INTERVAL = 0.4,   -- Time between spawns (higher = fewer particles)
	BASE_LEAVES_PER_TICK = 2,    -- Leaves per spawn tick
	
	-- Seasonal spawn multipliers
	-- Spring: barely any (trees are blooming, leaves are new)
	-- Summer: moderate falling (mature leaves, regular drop)
	-- Autumn: lots of falling (peak leaf fall)
	-- Winter: occasional (bare trees, stragglers)
	SEASON_SPAWN_MULTIPLIER = {
		Spring = 0.15,   -- 15% of normal (minimal)
		Summer = 0.5,    -- 50% of normal (noticeable but calm)
		Autumn = 1.0,    -- 100% (full autumn drop)
		Winter = 0.2,    -- 20% of normal (occasional stragglers)
	},
	
	-- Seasonal base colors (blended with source leaf color)
	-- 80% source color, 20% seasonal tint
	SEASON_LEAF_COLORS = {
		Spring = {
			Color3.fromRGB(120, 180, 80),   -- Fresh light green
			Color3.fromRGB(100, 170, 70),
			Color3.fromRGB(130, 190, 90),
		},
		Summer = {
			Color3.fromRGB(80, 140, 60),    -- Rich deep green
			Color3.fromRGB(70, 130, 50),
			Color3.fromRGB(90, 150, 70),
		},
		Autumn = {
			Color3.fromRGB(220, 120, 40),   -- Orange
			Color3.fromRGB(200, 80, 30),    -- Red-orange
			Color3.fromRGB(240, 180, 50),   -- Golden yellow
			Color3.fromRGB(180, 100, 40),   -- Brown-orange
			Color3.fromRGB(160, 60, 30),    -- Deep red
			Color3.fromRGB(210, 160, 60),   -- Light gold
		},
		Winter = {
			Color3.fromRGB(120, 90, 60),    -- Browns and dead colors
			Color3.fromRGB(100, 75, 50),
			Color3.fromRGB(140, 100, 70),
			Color3.fromRGB(90, 70, 45),
		},
	},
	
	-- Color variation amount (random shift applied to each leaf)
	COLOR_VARIATION = 0.15,
	
	-- Max distance from player to consider leaf blocks
	SEARCH_RADIUS = 60,
	
	-- Cache update interval
	CACHE_UPDATE_INTERVAL = 2,
	
	-- Particle settings
	SIZES = {0.4, 0.55, 0.7},  -- Three sizes for variety
	FALL_SPEED_MIN = 1.5,
	FALL_SPEED_MAX = 3.5,
	DRIFT_STRENGTH = 1.5,  -- Horizontal sway amount
	SPIN_SPEED_MIN = -100,
	SPIN_SPEED_MAX = 100,
	
	-- Ground settings
	MAX_FALL_DISTANCE = 80,   -- Max distance to fall before despawning
	REST_TIME_MIN = 4,        -- Min seconds to rest on ground
	REST_TIME_MAX = 8,        -- Max seconds to rest on ground
	FADE_OUT_TIME = 1.5,      -- Seconds to fade out after resting
	
	-- Max active particles (performance limit)
	MAX_PARTICLES = 60,
}

-- State
local emitterLeafCache = {}
local activeParticles = {}
local lastSpawnTime = 0
local lastCacheTime = 0
local currentSeason = "Summer"
local currentSpawnMultiplier = 0.5  -- Match summer default
local hasLoggedCache = false

-- Plot state
local currentPlotBlocksFolder = nil
local currentPlotCenter = nil
local currentPlotSize = nil

-- Container for falling leaves
local particleFolder = Instance.new("Folder")
particleFolder.Name = "FallingLeaves"
particleFolder.Parent = Workspace.Terrain

-- Get leaf color - mostly from source, with slight seasonal tint
-- Textured leaf blocks carry their colour on the face Texture/Decal objects, not
-- the part .Color. Prefer a visible texture's Color3 so falling leaves match what's
-- on screen; fall back to the part colour for untextured blocks.
local function visibleLeafColor(part)
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("Decal") and d.Transparency < 1 then  -- Texture is a subclass of Decal
			return d.Color3
		end
	end
	return part.Color
end

local function getSeasonalLeafColor(sourceColor)
	local seasonColors = CONFIG.SEASON_LEAF_COLORS[currentSeason]
	if not seasonColors or #seasonColors == 0 then
		return sourceColor
	end
	
	-- Pick a random seasonal color for slight tinting
	local tintColor = seasonColors[math.random(1, #seasonColors)]
	
	-- Blend: 80% source (actual tree), 20% seasonal tint
	local blendedColor = Color3.new(
		sourceColor.R * 0.8 + tintColor.R * 0.2,
		sourceColor.G * 0.8 + tintColor.G * 0.2,
		sourceColor.B * 0.8 + tintColor.B * 0.2
	)
	
	-- Apply small random variation
	local variation = CONFIG.COLOR_VARIATION
	local r = math.clamp(blendedColor.R + (math.random() - 0.5) * variation * 2, 0, 1)
	local g = math.clamp(blendedColor.G + (math.random() - 0.5) * variation * 2, 0, 1)
	local b = math.clamp(blendedColor.B + (math.random() - 0.5) * variation * 2, 0, 1)
	
	return Color3.new(r, g, b)
end

-- Update season data from plot
local function updateSeasonData()
	if currentPlotBlocksFolder then
		local buildArea = currentPlotBlocksFolder.Parent
		if buildArea then
			local newSeason = buildArea:GetAttribute("CurrentSeason")
			if newSeason and newSeason ~= currentSeason then
				currentSeason = newSeason
				print("[LeafParticleManager] Season changed to:", currentSeason)
			end
		end
	end
	
	currentSpawnMultiplier = CONFIG.SEASON_SPAWN_MULTIPLIER[currentSeason] or 0.3
end

-- Frame counter for staggered raycasts
local leafRaycastFrame = 0

-- Create a single falling leaf square
local function createFallingLeaf(position, sourceColor)
	if #activeParticles >= CONFIG.MAX_PARTICLES then return nil end
	
	-- NOTE: Spawn rate filtering is done in spawnLeafParticles, not here
	-- This avoids double-application of the multiplier
	
	-- Pick random size
	local size = CONFIG.SIZES[math.random(1, #CONFIG.SIZES)]
	
	-- Get seasonal color
	local leafColor = getSeasonalLeafColor(sourceColor)
	
	local leaf = Instance.new("Part")
	leaf.Name = "FallingLeaf"
	leaf.Size = Vector3.new(size, 0.05, size)
	leaf.Position = position
	leaf.Color = leafColor
	leaf.Material = Enum.Material.SmoothPlastic
	leaf.Anchored = true
	leaf.CanCollide = false
	leaf.CanQuery = false
	leaf.CanTouch = false
	leaf.CastShadow = false
	
	-- Random initial rotation
	leaf.CFrame = CFrame.new(position) * CFrame.Angles(
		math.rad(math.random(-20, 20)),
		math.rad(math.random(0, 360)),
		math.rad(math.random(-20, 20))
	)
	
	leaf.Parent = particleFolder
	
	-- Store animation data
	local leafData = {
		part = leaf,
		startTime = tick(),
		fallSpeed = CONFIG.FALL_SPEED_MIN + math.random() * (CONFIG.FALL_SPEED_MAX - CONFIG.FALL_SPEED_MIN),
		driftPhase = math.random() * math.pi * 2,
		driftFrequency = 0.7 + math.random() * 0.5,
		spinSpeed = CONFIG.SPIN_SPEED_MIN + math.random() * (CONFIG.SPIN_SPEED_MAX - CONFIG.SPIN_SPEED_MIN),
		wobblePhase = math.random() * math.pi * 2,
		startPos = position,
		color = leafColor,
		-- Ground landing state
		state = "falling",  -- "falling", "resting", "fading"
		groundY = nil,
		landedTime = nil,
		restDuration = CONFIG.REST_TIME_MIN + math.random() * (CONFIG.REST_TIME_MAX - CONFIG.REST_TIME_MIN),
		finalRotation = nil,
	}
	
	table.insert(activeParticles, leafData)
	return leafData
end

-- Raycast params for ground detection
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.FilterDescendantsInstances = {particleFolder}

-- Check if position is within plot bounds
local function isWithinPlotBounds(pos)
	if not currentPlotCenter or not currentPlotSize then
		return true
	end
	
	local halfSize = currentPlotSize / 2
	return pos.X >= currentPlotCenter.X - halfSize and pos.X <= currentPlotCenter.X + halfSize
	   and pos.Z >= currentPlotCenter.Z - halfSize and pos.Z <= currentPlotCenter.Z + halfSize
end

-- Update all active falling leaves
local function updateParticles(dt)
	local currentTime = tick()
	local toRemove = {}
	
	-- Increment frame counter for staggered raycasts
	leafRaycastFrame = leafRaycastFrame + 1
	
	-- Update raycast filter to exclude player character
	local character = player.Character
	if character then
		raycastParams.FilterDescendantsInstances = {particleFolder, character}
	end
	
	for i, data in ipairs(activeParticles) do
		if not data.part or not data.part.Parent then
			table.insert(toRemove, i)
			
		elseif data.state == "falling" then
			local age = currentTime - data.startTime
			local fallDistance = age * data.fallSpeed
			
			-- Check if fallen too far (no ground)
			if fallDistance > CONFIG.MAX_FALL_DISTANCE then
				table.insert(toRemove, i)
				data.part:Destroy()
			else
				-- Calculate new position with swaying motion
				local newY = data.startPos.Y - fallDistance
				
				-- Horizontal drift (sine wave for natural sway)
				local driftX = math.sin(age * data.driftFrequency + data.driftPhase) * CONFIG.DRIFT_STRENGTH
				local driftZ = math.cos(age * data.driftFrequency * 0.7 + data.wobblePhase) * CONFIG.DRIFT_STRENGTH * 0.6
				
				local newX = data.startPos.X + driftX
				local newZ = data.startPos.Z + driftZ
				local newPos = Vector3.new(newX, newY, newZ)
				
				-- Check if out of bounds
				if not isWithinPlotBounds(newPos) then
					table.insert(toRemove, i)
					data.part:Destroy()
				else
					-- Check for ground (staggered raycasts - only every 3rd frame per particle)
					-- This reduces raycast load by ~66% while still feeling responsive
					local shouldRaycast = ((leafRaycastFrame + i) % 3 == 0)
					local rayResult = nil
					
					if shouldRaycast then
						local rayOrigin = Vector3.new(newX, data.part.Position.Y + 0.5, newZ)
						local rayDirection = Vector3.new(0, -1, 0)
						rayResult = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)
					end
					
					if rayResult and rayResult.Position.Y >= newY then
						-- Hit ground! Land the leaf
						data.state = "resting"
						data.groundY = rayResult.Position.Y + 0.03
						data.landedTime = currentTime
						
						-- Flatten rotation to lie on ground
						local currentCFrame = data.part.CFrame
						local _, yRot, _ = currentCFrame:ToEulerAnglesYXZ()
						data.finalRotation = CFrame.new(newX, data.groundY, newZ) 
							* CFrame.Angles(0, yRot, 0)
							* CFrame.Angles(math.rad(math.random(-10, 10)), 0, math.rad(math.random(-10, 10)))
						
						data.part.CFrame = data.finalRotation
					else
						-- Still falling - update position and rotation
						local spin = data.spinSpeed * age
						local wobbleX = math.sin(age * 1.5 + data.wobblePhase) * 20
						local wobbleZ = math.cos(age * 1.2 + data.driftPhase) * 20
						
						data.part.CFrame = CFrame.new(newX, newY, newZ) 
							* CFrame.Angles(
								math.rad(wobbleX),
								math.rad(spin),
								math.rad(wobbleZ)
							)
					end
				end
			end
			
		elseif data.state == "resting" then
			local restTime = currentTime - data.landedTime
			
			if restTime >= data.restDuration then
				data.state = "fading"
				data.fadeStartTime = currentTime
			end
			
		elseif data.state == "fading" then
			local fadeProgress = (currentTime - data.fadeStartTime) / CONFIG.FADE_OUT_TIME
			
			if fadeProgress >= 1 then
				table.insert(toRemove, i)
				data.part:Destroy()
			else
				data.part.Transparency = fadeProgress
			end
		end
	end
	
	-- Remove expired particles (iterate backwards to preserve indices)
	for i = #toRemove, 1, -1 do
		table.remove(activeParticles, toRemove[i])
	end
end

-- Refresh the cache of emitter-eligible leaves nearby
local function updateLeafCache()
	emitterLeafCache = {}
	
	if not currentPlotBlocksFolder then return end
	
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end
	
	local searchPos = rootPart.Position
	local totalLeaves = 0
	local inRangeLeaves = 0
	
	-- Search only within our plot's blocks folder
	for _, block in ipairs(currentPlotBlocksFolder:GetChildren()) do
		-- Check if it's a leaf block (per-type: OakLeaves/BirchLeaves/SpruceLeaves,
		-- plus legacy "Leaves" -- substring match catches them all)
		local blockType = block:GetAttribute("BlockType")
		if blockType and blockType:find("Leaves") ~= nil then
			totalLeaves = totalLeaves + 1
			-- Check distance
			local blockPos
			if block:IsA("BasePart") then
				blockPos = block.Position
			elseif block:IsA("Model") then
				local primary = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
				if primary then blockPos = primary.Position end
			end
			
			if blockPos and (blockPos - searchPos).Magnitude < CONFIG.SEARCH_RADIUS then
				table.insert(emitterLeafCache, block)
				inRangeLeaves = inRangeLeaves + 1
			end
		end
	end
	
end

-- Spawn particles from random emitter leaves
local function spawnLeafParticles()
	if #emitterLeafCache == 0 then return end
	
	-- Adjust spawn count by season multiplier
	local adjustedLeavesPerTick = math.max(1, math.floor(CONFIG.BASE_LEAVES_PER_TICK * currentSpawnMultiplier + 0.5))
	
	for i = 1, adjustedLeavesPerTick do
		local randomIndex = math.random(1, #emitterLeafCache)
		local leaf = emitterLeafCache[randomIndex]
		
		if leaf and leaf.Parent then
			-- Get leaf position and color
			local leafPos, leafSize, leafColor
			
			if leaf:IsA("BasePart") then
				leafPos = leaf.Position
				leafSize = leaf.Size
				leafColor = visibleLeafColor(leaf)
			elseif leaf:IsA("Model") then
				local primary = leaf.PrimaryPart or leaf:FindFirstChildWhichIsA("BasePart")
				if primary then
					leafPos = primary.Position
					leafSize = primary.Size
					leafColor = visibleLeafColor(primary)
				end
			end
			
			if leafPos and leafSize and leafColor then
				-- Spawn position below the leaf block with slight random offset
				local spawnPos = leafPos - Vector3.new(
					(math.random() - 0.5) * leafSize.X * 0.8,
					leafSize.Y / 2 + 0.1,
					(math.random() - 0.5) * leafSize.Z * 0.8
				)
				
				createFallingLeaf(spawnPos, leafColor)
			end
		end
	end
end

-- Clear all particles
local function clearAllParticles()
	for _, data in ipairs(activeParticles) do
		if data.part and data.part.Parent then
			data.part:Destroy()
		end
	end
	activeParticles = {}
	emitterLeafCache = {}
end

-- Forward declaration for autoDetectPlot (defined later, used in setCurrentPlot)
local autoDetectPlot

-- Connection for detecting when blocks folder is destroyed/replaced
local blocksFolderDestroyedConnection = nil

-- Set the current plot to emit from
local function setCurrentPlot(blocksFolder, plotCenter, plotSize)
	-- Clear existing particles when switching plots
	clearAllParticles()
	
	-- Disconnect old folder watcher
	if blocksFolderDestroyedConnection then
		blocksFolderDestroyedConnection:Disconnect()
		blocksFolderDestroyedConnection = nil
	end
	
	currentPlotBlocksFolder = blocksFolder
	currentPlotCenter = plotCenter
	currentPlotSize = plotSize
	
	-- Reset cache logging flag so it prints again for new plot
	hasLoggedCache = false
	
	-- Update season immediately
	updateSeasonData()
	
	if blocksFolder then
		-- Watch for this folder being destroyed (e.g. terrain regeneration via ClearAllBlocks)
		-- When the folder is destroyed, clear all particles immediately
		blocksFolderDestroyedConnection = blocksFolder.AncestryChanged:Connect(function(_, newParent)
			if newParent == nil then
				print("[LeafParticleManager] Blocks folder destroyed - clearing all particles")
				clearAllParticles()
				currentPlotBlocksFolder = nil
				emitterLeafCache = {}
				if blocksFolderDestroyedConnection then
					blocksFolderDestroyedConnection:Disconnect()
					blocksFolderDestroyedConnection = nil
				end
				-- Re-detect plot after a short delay (new folder will exist)
				task.delay(1, autoDetectPlot)
			end
		end)
		
		-- Count leaves in the plot
		local leafCount = 0
		for _, block in ipairs(blocksFolder:GetChildren()) do
			local bt = block:GetAttribute("BlockType")
			if bt and bt:find("Leaves") ~= nil then
				leafCount = leafCount + 1
			end
		end
		print("[LeafParticleManager] Now watching plot at", plotCenter, "- found", leafCount, "leaf blocks")
	else
		print("[LeafParticleManager] Cleared plot - no leaves falling")
	end
end

-- Main loop
local lastSeasonUpdate = 0
local lastDebugPrint = 0
RunService.Heartbeat:Connect(function(dt)
	local currentTime = tick()
	
	-- Update season data periodically
	if currentTime - lastSeasonUpdate >= 3 then
		lastSeasonUpdate = currentTime
		updateSeasonData()
	end
	
	-- Update existing particles
	updateParticles(dt)
	
	-- Only spawn if we have a plot
	if not currentPlotBlocksFolder then return end
	
	-- Refresh leaf cache periodically
	if currentTime - lastCacheTime >= CONFIG.CACHE_UPDATE_INTERVAL then
		lastCacheTime = currentTime
		updateLeafCache()
		
		-- Debug: print cache status once when leaves are found
		if not hasLoggedCache and #emitterLeafCache > 0 then
			hasLoggedCache = true
			print(string.format("[LeafParticleManager] Found %d leaves in range, spawning particles (season: %s, multiplier: %.2f)",
				#emitterLeafCache, currentSeason, currentSpawnMultiplier))
		end
	end
	
	-- Spawn new particles (adjusted interval by season)
	local adjustedInterval = CONFIG.BASE_SPAWN_INTERVAL / math.max(0.1, currentSpawnMultiplier)
	if currentTime - lastSpawnTime >= adjustedInterval then
		lastSpawnTime = currentTime
		if #emitterLeafCache > 0 then
			spawnLeafParticles()
		end
	end
	
	-- Periodic debug output (every 10 seconds)
	if currentTime - lastDebugPrint >= 10 then
		lastDebugPrint = currentTime
		if #activeParticles > 0 or #emitterLeafCache > 0 then
			-- Only print if there's activity
		end
	end
end)

-- Listen for plot events (integrate with WeatherEvents)
local function connectToPlotEvents()
	local eventsFolder = ReplicatedStorage:WaitForChild("WeatherEvents", 10)
	if not eventsFolder then return end
	
	local weatherChanged = eventsFolder:FindFirstChild("WeatherChanged")
	if weatherChanged then
		weatherChanged.OnClientEvent:Connect(function(data)
			if data then
				-- When weather changes, we get plot info - use it to find blocks folder
				local plotCenter = data.plotCenter
				local plotSize = data.plotSize
				
				if plotCenter and plotSize then
					-- Find the build area at this position
					-- Build areas are directly in Workspace as BuildArea1, BuildArea2, etc.
					for i = 1, 20 do
						local buildArea = Workspace:FindFirstChild("BuildArea" .. i)
						if not buildArea then continue end
						
						local posX = buildArea:GetAttribute("BasePlatePositionX")
						local posZ = buildArea:GetAttribute("BasePlatePositionZ")
						
						if posX and posZ then
							-- Check if this is our plot
							if math.abs(posX - plotCenter.X) < 1 and math.abs(posZ - plotCenter.Z) < 1 then
								local blocksFolder = buildArea:FindFirstChild("Blocks")
								if blocksFolder then
									setCurrentPlot(blocksFolder, plotCenter, plotSize)
								end
								break
							end
						end
					end
				else
					-- No plot info - clear
					setCurrentPlot(nil, nil, nil)
				end
			end
		end)
	end
end

-- Also try to auto-detect player's plot
autoDetectPlot = function()
	local character = player.Character
	if not character then return end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end
	
	local playerPos = rootPart.Position
	
	-- Build areas are directly in Workspace as BuildArea1, BuildArea2, etc.
	for i = 1, 20 do -- Check up to 20 plots
		local buildArea = Workspace:FindFirstChild("BuildArea" .. i)
		if not buildArea then continue end
		
		local posX = buildArea:GetAttribute("BasePlatePositionX")
		local posZ = buildArea:GetAttribute("BasePlatePositionZ")
		local sizeX = buildArea:GetAttribute("BasePlateSizeX") or 100
		local sizeZ = buildArea:GetAttribute("BasePlateSizeZ") or 100
		
		if posX and posZ then
			local halfX = sizeX / 2
			local halfZ = sizeZ / 2
			
			-- Check if player is in this plot
			if playerPos.X >= posX - halfX and playerPos.X <= posX + halfX
			   and playerPos.Z >= posZ - halfZ and playerPos.Z <= posZ + halfZ then
				local blocksFolder = buildArea:FindFirstChild("Blocks")
				if blocksFolder then
					local plotCenter = Vector3.new(posX, 0, posZ)
					local plotSize = math.max(sizeX, sizeZ)
					setCurrentPlot(blocksFolder, plotCenter, plotSize)
					return
				end
			end
		end
	end
end

-- Periodic auto-detection
task.spawn(function()
	-- Wait for character first
	if not player.Character then
		player.CharacterAdded:Wait()
		task.wait(1) -- Give time for character to load
	end
	
	-- Initial detection
	autoDetectPlot()
	
	-- Keep checking periodically
	while true do
		task.wait(3)
		-- Re-detect if no folder, or if folder reference is stale (destroyed during terrain regen)
		if not currentPlotBlocksFolder or not currentPlotBlocksFolder.Parent then
			if currentPlotBlocksFolder and not currentPlotBlocksFolder.Parent then
				-- Stale reference - clear particles and reset
				clearAllParticles()
				currentPlotBlocksFolder = nil
				emitterLeafCache = {}
			end
			autoDetectPlot()
		end
	end
end)

-- Re-detect when character respawns
player.CharacterAdded:Connect(function()
	task.wait(1)
	autoDetectPlot()
end)

-- Cleanup on player leaving
Players.PlayerRemoving:Connect(function(leavingPlayer)
	if leavingPlayer == player then
		clearAllParticles()
		if particleFolder and particleFolder.Parent then
			particleFolder:Destroy()
		end
	end
end)

-- Listen for plot clearing event (from SaveManager when loading a different save)
local function connectToPlotClearingEvent()
	local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not Remotes then return end
	
	local PlotClearing = Remotes:WaitForChild("PlotClearing", 5)
	if PlotClearing then
		PlotClearing.OnClientEvent:Connect(function(plotNumber)
			print("[LeafParticleManager] Plot clearing event received, clearing all particles")
			clearAllParticles()
		end)
		print("[LeafParticleManager] Connected to PlotClearing event")
	end
end

-- Initialize
connectToPlotEvents()
connectToPlotClearingEvent()
updateSeasonData()
print("[LeafParticleManager] Initialized - physics-based falling leaves active")
print("[LeafParticleManager] Current season:", currentSeason, "| Spawn multiplier:", currentSpawnMultiplier)
