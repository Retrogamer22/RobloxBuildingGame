-- WeatherEffects.client.luau
-- Handles client-side precipitation particles with object pooling
-- Adapted from Ashborne weather system
-- Place in StarterPlayerScripts

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

-- ============================================
-- PARTICLE CONFIGURATIONS
-- ============================================

local RAIN_INTENSITIES = {
	Light = {
		particleCount = 40,
		dropSize = Vector3.new(0.08, 0.5, 0.08),
		fallSpeed = 45,
		fallSpeedVariation = 5,
		spreadRadius = 45,
		spawnHeight = 40,
		color = Color3.fromRGB(190, 210, 235),
		transparency = 0.5,
		soundVolume = 0.15,
	},
	Normal = {
		particleCount = 70,
		dropSize = Vector3.new(0.1, 0.7, 0.1),
		fallSpeed = 55,
		fallSpeedVariation = 8,
		spreadRadius = 50,
		spawnHeight = 45,
		color = Color3.fromRGB(180, 200, 230),
		transparency = 0.4,
		soundVolume = 0.25,
	},
	Heavy = {
		particleCount = 100,
		dropSize = Vector3.new(0.12, 0.9, 0.12),
		fallSpeed = 65,
		fallSpeedVariation = 10,
		spreadRadius = 55,
		spawnHeight = 50,
		color = Color3.fromRGB(170, 190, 220),
		transparency = 0.35,
		soundVolume = 0.4,
	},
	Storm = {
		particleCount = 140,
		dropSize = Vector3.new(0.14, 1.0, 0.14),
		fallSpeed = 75,
		fallSpeedVariation = 15,
		spreadRadius = 60,
		spawnHeight = 55,
		color = Color3.fromRGB(160, 180, 210),
		transparency = 0.3,
		soundVolume = 0.55,
	},
}

local SNOW_INTENSITIES = {
	Light = {
		particleCount = 30,
		sizes = {0.2, 0.3},
		fallSpeedMin = 3,
		fallSpeedMax = 6,
		driftStrength = 1.5,
		spreadRadius = 45,
		spawnHeight = 35,
		color = Color3.fromRGB(250, 250, 255),
		transparency = 0.15,
		soundVolume = 0.08,
	},
	Normal = {
		particleCount = 50,
		sizes = {0.25, 0.35},
		fallSpeedMin = 4,
		fallSpeedMax = 8,
		driftStrength = 2,
		spreadRadius = 50,
		spawnHeight = 40,
		color = Color3.fromRGB(248, 248, 255),
		transparency = 0.1,
		soundVolume = 0.12,
	},
	Heavy = {
		particleCount = 80,
		sizes = {0.3, 0.4},
		fallSpeedMin = 5,
		fallSpeedMax = 10,
		driftStrength = 2.5,
		spreadRadius = 55,
		spawnHeight = 45,
		color = Color3.fromRGB(245, 245, 255),
		transparency = 0.08,
		soundVolume = 0.18,
	},
	Storm = {
		particleCount = 110,
		sizes = {0.35, 0.5},
		fallSpeedMin = 6,
		fallSpeedMax = 12,
		driftStrength = 4,
		spreadRadius = 60,
		spawnHeight = 50,
		color = Color3.fromRGB(240, 242, 255),
		transparency = 0.05,
		soundVolume = 0.25,
	},
}

-- ============================================
-- PERFORMANCE CONFIG
-- ============================================

local CONFIG = {
	MAX_SPAWNS_PER_FRAME = 5,
	TRANSITION_TIME = 2,
	RAIN_SOUND_ID = "rbxassetid://9112854440",
	SNOW_SOUND_ID = "rbxassetid://9112854440",
	POOL_SIZE = 60,
}

-- ============================================
-- STATE
-- ============================================

local currentWeather = "Clear"
local currentIntensity = "Normal"
local currentPlotCenter = nil
local currentPlotSize = nil

local rainDrops = {}
local snowFlakes = {}

local weatherFolder = nil
local rainSound = nil
local snowSound = nil
local isSpawningEnabled = false

local activeRainSettings = RAIN_INTENSITIES.Normal
local activeSnowSettings = SNOW_INTENSITIES.Normal

-- Object pools
local rainPool = {}
local snowPool = {}

-- ============================================
-- OBJECT POOLING
-- ============================================

local function getFromPool(pool, createFunc)
	if #pool > 0 then
		return table.remove(pool)
	end
	return createFunc()
end

local function returnToPool(pool, obj)
	if #pool < CONFIG.POOL_SIZE then
		obj.Parent = nil
		table.insert(pool, obj)
	else
		obj:Destroy()
	end
end

-- ============================================
-- SETUP
-- ============================================

local function createWeatherFolder()
	if weatherFolder and weatherFolder.Parent then return weatherFolder end
	weatherFolder = Instance.new("Folder")
	weatherFolder.Name = "ClientWeatherEffects"
	weatherFolder.Parent = Workspace
	return weatherFolder
end

local function createSound(soundId, name)
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Volume = 0
	sound.Looped = true
	sound.Parent = player:WaitForChild("PlayerGui")
	return sound
end

local function setupSounds()
	if not rainSound then
		rainSound = createSound(CONFIG.RAIN_SOUND_ID, "RainSound")
	end
	if not snowSound then
		snowSound = createSound(CONFIG.SNOW_SOUND_ID, "SnowSound")
	end
end

local function fadeSound(sound, targetVolume, duration)
	if not sound then return end
	local tween = TweenService:Create(sound, TweenInfo.new(duration, Enum.EasingStyle.Linear), {Volume = targetVolume})
	tween:Play()
	if targetVolume > 0 and not sound.Playing then 
		sound:Play()
	elseif targetVolume == 0 then
		tween.Completed:Connect(function()
			if sound.Volume == 0 then sound:Stop() end
		end)
	end
end

-- ============================================
-- RAIN SYSTEM
-- ============================================

local function createRainDrop()
	local drop = Instance.new("Part")
	drop.Name = "RainDrop"
	drop.Material = Enum.Material.Glass
	drop.Anchored = true
	drop.CanCollide = false
	drop.CanQuery = false
	drop.CanTouch = false
	drop.CastShadow = false
	return drop
end

local function getSpawnPosition(settings)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return nil end
	
	local x, z, y
	
	if currentPlotCenter and currentPlotSize then
		-- STRICT PLOT BOUNDS: Spawn randomly within plot rectangle
		local halfSize = currentPlotSize / 2
		local minX = currentPlotCenter.X - halfSize
		local maxX = currentPlotCenter.X + halfSize
		local minZ = currentPlotCenter.Z - halfSize
		local maxZ = currentPlotCenter.Z + halfSize
		
		-- Random position within plot bounds
		x = minX + math.random() * currentPlotSize
		z = minZ + math.random() * currentPlotSize
		y = root.Position.Y + settings.spawnHeight
	else
		-- Fallback: circular around player if no plot bounds
		local angle = math.random() * math.pi * 2
		local distance = math.random() * settings.spreadRadius
		x = root.Position.X + math.cos(angle) * distance
		z = root.Position.Z + math.sin(angle) * distance
		y = root.Position.Y + settings.spawnHeight
	end
	
	return Vector3.new(x, y, z), root.Position.Y
end

-- Check if position is within plot bounds
local function isWithinPlotBounds(x, z)
	if not currentPlotCenter or not currentPlotSize then
		return true -- No bounds, always valid
	end
	
	local halfSize = currentPlotSize / 2
	return x >= currentPlotCenter.X - halfSize and x <= currentPlotCenter.X + halfSize
	   and z >= currentPlotCenter.Z - halfSize and z <= currentPlotCenter.Z + halfSize
end

local function spawnRainDrop(settings)
	local pos, baseY = getSpawnPosition(settings)
	if not pos then return end
	
	local drop = getFromPool(rainPool, createRainDrop)
	drop.Size = settings.dropSize
	drop.Color = settings.color
	drop.Transparency = settings.transparency
	drop.Position = pos
	drop.Parent = weatherFolder
	
	table.insert(rainDrops, {
		part = drop,
		velocity = settings.fallSpeed + (math.random() - 0.5) * settings.fallSpeedVariation * 2,
		baseY = baseY,
	})
end

local function updateRain(dt, settings)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return end
	
	local playerY = root.Position.Y
	local groundLevel = playerY - 30
	local toRemove = {}
	
	for i, data in ipairs(rainDrops) do
		local drop = data.part
		if drop and drop.Parent then
			local pos = drop.Position
			local newY = pos.Y - data.velocity * dt
			
			-- Check if out of bounds OR hit ground
			local outOfBounds = not isWithinPlotBounds(pos.X, pos.Z)
			local hitGround = newY < groundLevel
			
			if outOfBounds or hitGround then
				if isSpawningEnabled then
					-- Respawn at top within bounds
					local newPos, baseY = getSpawnPosition(settings)
					if newPos then
						drop.Position = newPos
						data.velocity = settings.fallSpeed + (math.random() - 0.5) * settings.fallSpeedVariation * 2
						data.baseY = baseY
					else
						table.insert(toRemove, i)
					end
				else
					table.insert(toRemove, i)
				end
			else
				drop.Position = Vector3.new(pos.X, newY, pos.Z)
			end
		else
			table.insert(toRemove, i)
		end
	end
	
	-- Remove from end to preserve indices
	for i = #toRemove, 1, -1 do
		local data = rainDrops[toRemove[i]]
		if data and data.part then returnToPool(rainPool, data.part) end
		table.remove(rainDrops, toRemove[i])
	end
	
	-- Spawn new drops (batched)
	if isSpawningEnabled then
		local spawnsNeeded = settings.particleCount - #rainDrops
		for i = 1, math.min(spawnsNeeded, CONFIG.MAX_SPAWNS_PER_FRAME) do
			spawnRainDrop(settings)
		end
	end
end

-- ============================================
-- SNOW SYSTEM
-- ============================================

local function createSnowFlake()
	local flake = Instance.new("Part")
	flake.Name = "SnowFlake"
	flake.Shape = Enum.PartType.Ball
	flake.Material = Enum.Material.SmoothPlastic
	flake.Anchored = true
	flake.CanCollide = false
	flake.CanQuery = false
	flake.CanTouch = false
	flake.CastShadow = false
	return flake
end

local function spawnSnowFlake(settings)
	local pos, baseY = getSpawnPosition(settings)
	if not pos then return end
	
	local flake = getFromPool(snowPool, createSnowFlake)
	local size = settings.sizes[math.random(1, #settings.sizes)]
	flake.Size = Vector3.new(size, size, size)
	flake.Color = settings.color
	flake.Transparency = settings.transparency
	flake.Position = pos
	flake.Parent = weatherFolder
	
	table.insert(snowFlakes, {
		part = flake,
		velocity = settings.fallSpeedMin + math.random() * (settings.fallSpeedMax - settings.fallSpeedMin),
		driftPhase = math.random() * math.pi * 2,
		driftStrength = settings.driftStrength,
		startTime = tick(),
		baseY = baseY,
	})
end

local function updateSnow(dt, settings)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return end
	
	local playerY = root.Position.Y
	local groundLevel = playerY - 30
	local toRemove = {}
	local now = tick()
	
	for i, data in ipairs(snowFlakes) do
		local flake = data.part
		if flake and flake.Parent then
			local pos = flake.Position
			local age = now - data.startTime
			local newY = pos.Y - data.velocity * dt
			
			-- Gentle drifting
			local driftX = math.sin(age * 0.5 + data.driftPhase) * data.driftStrength * dt
			local driftZ = math.cos(age * 0.35 + data.driftPhase) * data.driftStrength * dt
			
			local newX = pos.X + driftX
			local newZ = pos.Z + driftZ
			
			-- Check if out of bounds OR hit ground
			local outOfBounds = not isWithinPlotBounds(newX, newZ)
			local hitGround = newY < groundLevel
			
			if outOfBounds or hitGround then
				if isSpawningEnabled then
					local newPos, baseY = getSpawnPosition(settings)
					if newPos then
						flake.Position = newPos
						data.velocity = settings.fallSpeedMin + math.random() * (settings.fallSpeedMax - settings.fallSpeedMin)
						data.startTime = now
						data.baseY = baseY
					else
						table.insert(toRemove, i)
					end
				else
					table.insert(toRemove, i)
				end
			else
				flake.Position = Vector3.new(newX, newY, newZ)
			end
		else
			table.insert(toRemove, i)
		end
	end
	
	for i = #toRemove, 1, -1 do
		local data = snowFlakes[toRemove[i]]
		if data and data.part then returnToPool(snowPool, data.part) end
		table.remove(snowFlakes, toRemove[i])
	end
	
	if isSpawningEnabled then
		local spawnsNeeded = settings.particleCount - #snowFlakes
		for i = 1, math.min(spawnsNeeded, CONFIG.MAX_SPAWNS_PER_FRAME) do
			spawnSnowFlake(settings)
		end
	end
end

-- ============================================
-- WEATHER TRANSITIONS
-- ============================================

local function destroyAllParticles()
	for _, data in ipairs(rainDrops) do
		if data.part then data.part:Destroy() end
	end
	rainDrops = {}
	
	for _, data in ipairs(snowFlakes) do
		if data.part then data.part:Destroy() end
	end
	snowFlakes = {}
end

local function setWeatherEffects(weather, intensity, plotCenter, plotSize)
	currentWeather = weather
	currentIntensity = intensity or "Normal"
	currentPlotCenter = plotCenter
	currentPlotSize = plotSize
	
	activeRainSettings = RAIN_INTENSITIES[currentIntensity] or RAIN_INTENSITIES.Normal
	activeSnowSettings = SNOW_INTENSITIES[currentIntensity] or SNOW_INTENSITIES.Normal
	
	createWeatherFolder()
	setupSounds()
	
	if weather == "Clear" then
		isSpawningEnabled = false
		fadeSound(rainSound, 0, CONFIG.TRANSITION_TIME)
		fadeSound(snowSound, 0, CONFIG.TRANSITION_TIME)
		
	elseif weather == "Rain" or weather == "Storm" then
		isSpawningEnabled = true
		local volume = weather == "Storm" and RAIN_INTENSITIES.Storm.soundVolume or activeRainSettings.soundVolume
		fadeSound(rainSound, volume, CONFIG.TRANSITION_TIME)
		fadeSound(snowSound, 0, CONFIG.TRANSITION_TIME)
		-- Clear snow if switching from snow
		for _, data in ipairs(snowFlakes) do
			if data.part then returnToPool(snowPool, data.part) end
		end
		snowFlakes = {}
		
	elseif weather == "Snow" then
		isSpawningEnabled = true
		fadeSound(snowSound, activeSnowSettings.soundVolume, CONFIG.TRANSITION_TIME)
		fadeSound(rainSound, 0, CONFIG.TRANSITION_TIME)
		-- Clear rain if switching from rain
		for _, data in ipairs(rainDrops) do
			if data.part then returnToPool(rainPool, data.part) end
		end
		rainDrops = {}
		
	elseif weather == "Fog" then
		-- Fog uses server-side particle emitters, just handle sound
		isSpawningEnabled = false
		fadeSound(rainSound, 0, CONFIG.TRANSITION_TIME)
		fadeSound(snowSound, 0, CONFIG.TRANSITION_TIME)
	end
	
	print("[WeatherEffects] Weather:", weather, "Intensity:", currentIntensity)
end

-- ============================================
-- UPDATE LOOP
-- ============================================

RunService.Heartbeat:Connect(function(dt)
	if currentWeather == "Rain" then
		updateRain(dt, activeRainSettings)
	elseif currentWeather == "Storm" then
		updateRain(dt, RAIN_INTENSITIES.Storm)
	elseif currentWeather == "Snow" then
		updateSnow(dt, activeSnowSettings)
	elseif currentWeather == "Clear" or currentWeather == "Fog" then
		-- Let particles finish falling
		if #rainDrops > 0 then updateRain(dt, activeRainSettings) end
		if #snowFlakes > 0 then updateSnow(dt, activeSnowSettings) end
	end
end)

-- ============================================
-- EVENTS
-- ============================================

local function connectToWeatherEvents()
	local eventsFolder = ReplicatedStorage:WaitForChild("WeatherEvents", 10)
	if not eventsFolder then
		-- Create it if it doesn't exist (server should create it)
		eventsFolder = Instance.new("Folder")
		eventsFolder.Name = "WeatherEvents"
		eventsFolder.Parent = ReplicatedStorage
	end
	
	local weatherChanged = eventsFolder:FindFirstChild("WeatherChanged")
	if not weatherChanged then
		weatherChanged = Instance.new("RemoteEvent")
		weatherChanged.Name = "WeatherChanged"
		weatherChanged.Parent = eventsFolder
	end
	
	weatherChanged.OnClientEvent:Connect(function(data)
		if data and data.weather then
			setWeatherEffects(
				data.weather, 
				data.intensity,
				data.plotCenter,
				data.plotSize
			)
		end
	end)
end

-- ============================================
-- CLEANUP
-- ============================================

player.CharacterRemoving:Connect(destroyAllParticles)

-- ============================================
-- INIT
-- ============================================

createWeatherFolder()
connectToWeatherEvents()

print("[WeatherEffects] Client-side weather initialized")
print("  Object pooling enabled")
print("  Rain pool size:", CONFIG.POOL_SIZE)
print("  Snow pool size:", CONFIG.POOL_SIZE)
