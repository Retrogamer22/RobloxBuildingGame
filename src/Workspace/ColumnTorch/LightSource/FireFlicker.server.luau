-- FireFlicker
-- Makes all SurfaceLights flicker smoothly like a real fire (synced)
-- Cooperates with LightingManager: reads "AdjustedBrightness" attribute
-- as the base to flicker around, so overlapping lights don't blow out.

local lightSource = script.Parent

-- Collect all SurfaceLights in this LightSource part
local surfaceLights = {}
for _, child in ipairs(lightSource:GetChildren()) do
	if child:IsA("SurfaceLight") then
		table.insert(surfaceLights, child)
	end
end

if #surfaceLights == 0 then
	warn("[FireFlicker] No SurfaceLights found in " .. lightSource:GetFullName())
	return
end

-- Base values (used as defaults if LightingManager hasn't set an adjusted value yet)
local DEFAULT_BRIGHTNESS = 2
local DEFAULT_RANGE = 18

-- Flicker intensity (how much it varies as a FRACTION of base brightness)
local BRIGHTNESS_FLICKER_FRACTION = 0.2   -- 20% of base brightness
local RANGE_FLICKER = 3

-- Smoothing (higher = smoother, 0.1 is very smooth, 0.5 is more responsive)
local SMOOTHING = 0.15

-- How often to pick a new target
local TARGET_CHANGE_TIME = 0.15

-- Mark ALL surface lights so LightingManager knows they're flicker lights
for _, light in ipairs(surfaceLights) do
	light:SetAttribute("IsFlickerLight", true)
	light:SetAttribute("FlickerBaseBrightness", DEFAULT_BRIGHTNESS)
	light:SetAttribute("FlickerBaseRange", DEFAULT_RANGE)
end

-- Current values (shared across all lights for sync)
local currentBrightness = DEFAULT_BRIGHTNESS
local currentRange = DEFAULT_RANGE

-- Target values
local targetBrightness = DEFAULT_BRIGHTNESS
local targetRange = DEFAULT_RANGE

local timeSinceChange = 0

while true do
	local dt = task.wait()
	timeSinceChange = timeSinceChange + dt

	-- Read the adjusted base from LightingManager via the first light (all get same value)
	local baseBrightness = surfaceLights[1]:GetAttribute("AdjustedBrightness") or DEFAULT_BRIGHTNESS
	local baseRange = surfaceLights[1]:GetAttribute("AdjustedRange") or DEFAULT_RANGE

	-- Calculate flicker amount relative to current base
	local brightnessFlicker = baseBrightness * BRIGHTNESS_FLICKER_FRACTION

	-- Pick new random targets periodically
	if timeSinceChange >= TARGET_CHANGE_TIME then
		targetBrightness = baseBrightness + (math.random() - 0.5) * 2 * brightnessFlicker
		targetRange = baseRange + (math.random() - 0.5) * 2 * RANGE_FLICKER

		-- Clamp so it never goes negative or crazy
		targetBrightness = math.max(targetBrightness, 0.05)
		targetRange = math.max(targetRange, 2)

		timeSinceChange = 0
	else
		-- If the base changed mid-cycle (LightingManager adjusted),
		-- smoothly shift our targets to stay relative
		targetBrightness = math.max(baseBrightness + (targetBrightness - baseBrightness) * 0.5, 0.05)
	end

	-- Smoothly lerp toward targets
	currentBrightness = currentBrightness + (targetBrightness - currentBrightness) * SMOOTHING
	currentRange = currentRange + (targetRange - currentRange) * SMOOTHING

	-- Apply to ALL surface lights (synced flicker)
	for _, light in ipairs(surfaceLights) do
		light.Brightness = currentBrightness
		light.Range = currentRange
	end
end