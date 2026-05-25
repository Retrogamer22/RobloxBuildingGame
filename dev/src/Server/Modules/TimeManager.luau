--[[
	TimeManager
	Handles per-plot time of day through local lighting effects
	
	Time Settings:
	- Dawn: Early morning golden light
	- Day: Bright daylight
	- Sunset: Golden hour
	- Night: Dark with moonlight
	- Cycle: Natural day/night cycle
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local TimeManager = {}

-- Store active time setting per plot
local PlotTime = {}
local PlotTimeEffects = {}

-- Time configurations (ClockTime values and lighting settings)
local TimeConfig = {
	Dawn = {
		ClockTime = 6,
		Brightness = 1.5,
		Ambient = Color3.fromRGB(150, 130, 120),
		OutdoorAmbient = Color3.fromRGB(170, 140, 120),
		ColorShift_Top = Color3.fromRGB(255, 200, 150),
		ColorShift_Bottom = Color3.fromRGB(150, 130, 140),
		ShadowSoftness = 0.3,
	},
	Day = {
		ClockTime = 14,
		Brightness = 2,
		Ambient = Color3.fromRGB(135, 135, 135),
		OutdoorAmbient = Color3.fromRGB(135, 135, 135),
		ColorShift_Top = Color3.fromRGB(0, 0, 0),
		ColorShift_Bottom = Color3.fromRGB(0, 0, 0),
		ShadowSoftness = 0.2,
	},
	Sunset = {
		ClockTime = 18,
		Brightness = 1.8,
		Ambient = Color3.fromRGB(180, 130, 100),
		OutdoorAmbient = Color3.fromRGB(200, 140, 100),
		ColorShift_Top = Color3.fromRGB(255, 150, 100),
		ColorShift_Bottom = Color3.fromRGB(180, 100, 80),
		ShadowSoftness = 0.4,
	},
	Night = {
		ClockTime = 0,
		Brightness = 0.5,
		Ambient = Color3.fromRGB(50, 50, 70),
		OutdoorAmbient = Color3.fromRGB(40, 40, 60),
		ColorShift_Top = Color3.fromRGB(50, 50, 80),
		ColorShift_Bottom = Color3.fromRGB(30, 30, 50),
		ShadowSoftness = 0.5,
		HasStars = true,
		MoonBrightness = 0.3,
	},
	Cycle = {
		-- Uses natural day/night cycle
		CycleSpeed = 1, -- 1 = normal, 2 = double speed, etc.
	},
}

-- Create local lighting for a plot (using a spotlight/surface light)
local function createPlotLighting(buildArea, timeType)
	local config = TimeConfig[timeType]
	if not config or timeType == "Cycle" then return nil end
	
	-- Get plot bounds
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX") or 100
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ") or 100
	local surfaceY = buildArea:GetAttribute("TerrainSurfaceY") or 5
	
	if not posX or not posZ then return nil end
	
	-- Create ambient light emitter
	local lightPart = Instance.new("Part")
	lightPart.Name = "PlotAmbientLight"
	lightPart.Size = Vector3.new(sizeX, 1, sizeZ)
	lightPart.Position = Vector3.new(posX, surfaceY + 40, posZ)
	lightPart.Anchored = true
	lightPart.CanCollide = false
	lightPart.CanQuery = false
	lightPart.Transparency = 1
	lightPart.Parent = buildArea
	
	-- Create color correction effect as a visual cue
	-- Note: True per-plot lighting would require more complex solutions
	-- This creates a subtle ambient light to hint at the time
	
	local light = Instance.new("PointLight")
	light.Name = "TimeLight"
	light.Range = math.max(sizeX, sizeZ) * 1.5
	light.Brightness = config.Brightness * 0.3
	light.Color = config.ColorShift_Top ~= Color3.fromRGB(0, 0, 0) and config.ColorShift_Top or Color3.fromRGB(255, 255, 255)
	light.Shadows = false
	light.Parent = lightPart
	
	-- Night gets additional moon-like light
	if timeType == "Night" then
		local moonLight = Instance.new("PointLight")
		moonLight.Name = "MoonLight"
		moonLight.Range = math.max(sizeX, sizeZ) * 1.2
		moonLight.Brightness = 0.2
		moonLight.Color = Color3.fromRGB(180, 190, 220)
		moonLight.Shadows = false
		moonLight.Parent = lightPart
	end
	
	return lightPart
end

-- Create star particles for night time
local function createStarEffect(buildArea)
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX") or 100
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ") or 100
	local surfaceY = buildArea:GetAttribute("TerrainSurfaceY") or 5
	
	if not posX or not posZ then return nil end
	
	-- Create a "sky dome" effect with twinkling stars
	local starPart = Instance.new("Part")
	starPart.Name = "StarField"
	starPart.Size = Vector3.new(sizeX, 1, sizeZ)
	starPart.Position = Vector3.new(posX, surfaceY + 80, posZ)
	starPart.Anchored = true
	starPart.CanCollide = false
	starPart.CanQuery = false
	starPart.Transparency = 1
	starPart.Parent = buildArea
	
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Stars"
	emitter.Rate = 0 -- We'll use Emit for static stars
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200, 220, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 200)),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.2, 0.15),
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(0.8, 0.15),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 0.3),
		NumberSequenceKeypoint.new(0.7, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(3, 5)
	emitter.Speed = NumberRange.new(0, 0)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Texture = "rbxassetid://243660364"
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Parent = starPart
	
	-- Emit a bunch of stars periodically
	task.spawn(function()
		while starPart.Parent do
			emitter:Emit(20)
			task.wait(2)
		end
	end)
	
	return starPart
end

-- Clear time effects for a plot
local function clearTimeEffects(plotNumber)
	local effects = PlotTimeEffects[plotNumber]
	if not effects then return end
	
	if effects.cycleConnection then
		effects.cycleConnection:Disconnect()
		effects.cycleConnection = nil
	end
	
	if effects.lightPart then
		effects.lightPart:Destroy()
		effects.lightPart = nil
	end
	
	if effects.starPart then
		effects.starPart:Destroy()
		effects.starPart = nil
	end
	
	PlotTimeEffects[plotNumber] = nil
end

-- Set time for a plot
function TimeManager.SetTime(buildArea, plotNumber, timeType)
	if not buildArea or not plotNumber then return end
	if not TimeConfig[timeType] then
		timeType = "Day"
	end
	
	-- Clear existing effects
	clearTimeEffects(plotNumber)
	
	-- Store new time
	PlotTime[plotNumber] = timeType
	buildArea:SetAttribute("CurrentTimeOfDay", timeType)
	
	-- Create new effects
	PlotTimeEffects[plotNumber] = {}
	local effects = PlotTimeEffects[plotNumber]
	
	if timeType == "Cycle" then
		-- Natural cycle - no special effects needed, uses global lighting
		print("[TimeManager] Set time to Cycle (natural) for plot " .. plotNumber)
		return
	end
	
	-- Create plot lighting
	effects.lightPart = createPlotLighting(buildArea, timeType)
	
	-- Night gets stars
	if timeType == "Night" then
		effects.starPart = createStarEffect(buildArea)
	end
	
	print("[TimeManager] Set time to " .. timeType .. " for plot " .. plotNumber)
end

-- Get current time setting for a plot
function TimeManager.GetTime(plotNumber)
	return PlotTime[plotNumber] or "Day"
end

-- Get actual clock time for a time type
function TimeManager.GetClockTime(timeType)
	local config = TimeConfig[timeType]
	if config and config.ClockTime then
		return config.ClockTime
	end
	return 14 -- Default to day
end

-- Clean up when plot is released
function TimeManager.ClearPlot(plotNumber)
	clearTimeEffects(plotNumber)
	PlotTime[plotNumber] = nil
end

-- Get time config
function TimeManager.GetTimeConfig(timeType)
	return TimeConfig[timeType]
end

return TimeManager
