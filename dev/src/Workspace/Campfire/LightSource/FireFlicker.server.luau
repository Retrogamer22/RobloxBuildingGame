-- Script inside the light source block
-- Makes the PointLight flicker smoothly like a real fire

local pointLight = script.Parent:WaitForChild("PointLight")

-- Base values (adjust these to your liking)
local baseBrightness = 2
local baseRange = 18

-- Flicker intensity (how much it varies)
local brightnessFlicker = 0.4
local rangeFlicker = 3

-- Smoothing (higher = smoother, 0.1 is very smooth, 0.5 is more responsive)
local smoothing = 0.15

-- Current values
local currentBrightness = baseBrightness
local currentRange = baseRange

-- Target values
local targetBrightness = baseBrightness
local targetRange = baseRange

-- How often to pick a new target
local targetChangeTime = 0.15
local timeSinceChange = 0

while true do
	local dt = task.wait()
	timeSinceChange = timeSinceChange + dt

	-- Pick new random targets periodically
	if timeSinceChange >= targetChangeTime then
		targetBrightness = baseBrightness + (math.random() - 0.5) * 2 * brightnessFlicker
		targetRange = baseRange + (math.random() - 0.5) * 2 * rangeFlicker
		timeSinceChange = 0
	end

	-- Smoothly lerp toward targets
	currentBrightness = currentBrightness + (targetBrightness - currentBrightness) * smoothing
	currentRange = currentRange + (targetRange - currentRange) * smoothing

	pointLight.Brightness = currentBrightness
	pointLight.Range = currentRange
end