--[[
	WeatherManager
	Handles per-plot weather effects
	Server-side controller that communicates with client-side particle rendering
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local WeatherManager = {}

-- ============================================
-- STATE
-- ============================================

local PlotWeather = {}
local PlotWeatherEffects = {}

-- ============================================
-- EVENTS SETUP
-- ============================================

local function getEventsFolder()
	local folder = ReplicatedStorage:FindFirstChild("WeatherEvents")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "WeatherEvents"
		folder.Parent = ReplicatedStorage
	end
	return folder
end

local function getWeatherChangedEvent()
	local folder = getEventsFolder()
	local event = folder:FindFirstChild("WeatherChanged")
	if not event then
		event = Instance.new("RemoteEvent")
		event.Name = "WeatherChanged"
		event.Parent = folder
	end
	return event
end

-- ============================================
-- LIGHTNING EFFECTS (Server-side)
-- ============================================

local function createLightningFlash(buildArea)
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX") or 100
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ") or 100
	local surfaceY = buildArea:GetAttribute("TerrainSurfaceY") or 5
	
	if not posX or not posZ then return end
	
	local lightX = posX + (math.random() - 0.5) * sizeX * 0.8
	local lightZ = posZ + (math.random() - 0.5) * sizeZ * 0.8
	
	local flashPart = Instance.new("Part")
	flashPart.Name = "Lightning"
	flashPart.Size = Vector3.new(1, 1, 1)
	flashPart.Position = Vector3.new(lightX, surfaceY + 35, lightZ)
	flashPart.Anchored = true
	flashPart.CanCollide = false
	flashPart.Transparency = 1
	flashPart.Parent = buildArea
	
	local light = Instance.new("PointLight")
	light.Brightness = 20
	light.Range = 200
	light.Color = Color3.fromRGB(230, 230, 255)
	light.Parent = flashPart
	
	task.spawn(function()
		for i = 1, math.random(2, 4) do
			light.Enabled = true
			task.wait(0.04)
			light.Enabled = false
			task.wait(0.02 + math.random() * 0.06)
		end
		
		task.wait(1)
		flashPart:Destroy()
	end)
	
	Debris:AddItem(flashPart, 5)
end

local function startLightningLoop(buildArea, plotNumber)
	local effects = PlotWeatherEffects[plotNumber]
	if not effects then return end
	
	effects.lightningActive = true
	
	task.spawn(function()
		while effects.lightningActive and PlotWeather[plotNumber] == "Storm" do
			task.wait(2 + math.random() * 5)
			if effects.lightningActive and PlotWeather[plotNumber] == "Storm" then
				createLightningFlash(buildArea)
			end
		end
	end)
end

-- ============================================
-- FOG EFFECTS (Server-side particle emitters)
-- ============================================

local function createFogEffect(buildArea)
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX") or 100
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ") or 100
	local surfaceY = buildArea:GetAttribute("TerrainSurfaceY") or 5
	
	if not posX or not posZ then return nil end
	
	local folder = Instance.new("Folder")
	folder.Name = "WeatherEffects"
	folder.Parent = buildArea
	
	local emitterCount = 3
	local spacing = sizeX / emitterCount
	
	for x = 0, emitterCount - 1 do
		for z = 0, emitterCount - 1 do
			local offsetX = (x - (emitterCount - 1) / 2) * spacing
			local offsetZ = (z - (emitterCount - 1) / 2) * spacing
			
			local emitterPart = Instance.new("Part")
			emitterPart.Name = "FogEmitter_" .. x .. "_" .. z
			emitterPart.Size = Vector3.new(spacing, 1, spacing)
			emitterPart.Position = Vector3.new(posX + offsetX, surfaceY + 5, posZ + offsetZ)
			emitterPart.Anchored = true
			emitterPart.CanCollide = false
			emitterPart.CanQuery = false
			emitterPart.Transparency = 1
			emitterPart.Parent = folder
			
			local emitter = Instance.new("ParticleEmitter")
			emitter.Name = "Fog"
			emitter.Rate = 5
			emitter.Color = ColorSequence.new(Color3.fromRGB(220, 220, 230))
			emitter.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.2, 0.6),
				NumberSequenceKeypoint.new(0.8, 0.6),
				NumberSequenceKeypoint.new(1, 1),
			})
			emitter.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 15),
				NumberSequenceKeypoint.new(0.5, 25),
				NumberSequenceKeypoint.new(1, 20),
			})
			emitter.Lifetime = NumberRange.new(10, 15)
			emitter.Speed = NumberRange.new(1, 3)
			emitter.SpreadAngle = Vector2.new(180, 0)
			emitter.EmissionDirection = Enum.NormalId.Top
			emitter.Acceleration = Vector3.new(0, 0.5, 0)
			emitter.Drag = 1
			emitter.RotSpeed = NumberRange.new(-5, 5)
			emitter.Rotation = NumberRange.new(0, 360)
			emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
			emitter.LightEmission = 0
			emitter.LightInfluence = 1
			emitter.ZOffset = -1
			emitter.Enabled = true
			emitter.Parent = emitterPart
		end
	end
	
	return folder
end

-- ============================================
-- CLEAR EFFECTS
-- ============================================

local function clearWeatherEffects(plotNumber)
	local effects = PlotWeatherEffects[plotNumber]
	if not effects then return end
	
	effects.lightningActive = false
	
	if effects.folder then
		effects.folder:Destroy()
		effects.folder = nil
	end
	
	PlotWeatherEffects[plotNumber] = nil
end

-- ============================================
-- NOTIFY PLAYER (find plot owner)
-- ============================================

local function notifyPlotOwner(buildArea, weatherType, intensity)
	local ownerUserId = buildArea:GetAttribute("OwnerUserId")
	if not ownerUserId then return end
	
	local player = Players:GetPlayerByUserId(ownerUserId)
	if not player then return end
	
	local event = getWeatherChangedEvent()
	
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX") or 100
	
	local plotCenter = nil
	if posX and posZ then
		plotCenter = Vector3.new(posX, 0, posZ)
	end
	
	local data = {
		weather = weatherType,
		intensity = intensity or "Normal",
		plotCenter = plotCenter,
		plotSize = sizeX,
	}
	
	event:FireClient(player, data)
	print("[WeatherManager] Notified", player.Name, "of weather:", weatherType)
end

-- ============================================
-- PUBLIC API
-- ============================================

function WeatherManager.SetWeather(buildArea, plotNumber, weatherType, intensity)
	if not buildArea or not plotNumber then return end
	
	weatherType = weatherType or "Clear"
	intensity = intensity or "Normal"
	
	print("[WeatherManager] Setting", weatherType, "(", intensity, ") for plot", plotNumber)
	
	-- Clear existing effects
	clearWeatherEffects(plotNumber)
	
	local existingFolder = buildArea:FindFirstChild("WeatherEffects")
	if existingFolder then
		existingFolder:Destroy()
	end
	
	-- Update state
	PlotWeather[plotNumber] = weatherType
	buildArea:SetAttribute("CurrentWeather", weatherType)
	buildArea:SetAttribute("WeatherIntensity", intensity)
	
	-- Handle server-side effects
	if weatherType ~= "Clear" then
		PlotWeatherEffects[plotNumber] = {}
		local effects = PlotWeatherEffects[plotNumber]
		
		if weatherType == "Fog" then
			-- Fog uses server-side particle emitters
			effects.folder = createFogEffect(buildArea)
		elseif weatherType == "Storm" then
			-- Storm uses client-side rain + server-side lightning
			startLightningLoop(buildArea, plotNumber)
		end
		-- Rain and Snow are handled entirely client-side
	end
	
	-- Notify the plot owner
	notifyPlotOwner(buildArea, weatherType, intensity)
end

function WeatherManager.GetWeather(plotNumber)
	return PlotWeather[plotNumber] or "Clear"
end

function WeatherManager.GetIntensity(plotNumber, buildArea)
	if buildArea then
		return buildArea:GetAttribute("WeatherIntensity") or "Normal"
	end
	return "Normal"
end

function WeatherManager.ClearPlot(plotNumber)
	clearWeatherEffects(plotNumber)
	PlotWeather[plotNumber] = nil
end

-- Initialize events folder
getEventsFolder()
getWeatherChangedEvent()

print("[WeatherManager] Server initialized")

return WeatherManager
