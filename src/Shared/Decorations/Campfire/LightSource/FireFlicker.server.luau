-- Script inside the campfire's LightSource model.
-- Makes the PointLight flicker smoothly like a real fire.
--
-- IMPORTANT: This script honors LightingManager's auto-leveling.
-- LightingManager sets two attributes on the PointLight when nearby lights overlap:
--   - AdjustedBrightness: the brightness this light *should* center on right now
--   - AdjustedRange:      the range this light *should* center on right now
-- We read those each frame as the flicker's base, so when several campfires sit close
-- together, LightingManager dims them and we flicker around the dimmed value instead
-- of blasting brightness=2 forever.
--
-- If those attributes are absent (e.g. LightingManager hasn't tracked us yet), we
-- fall back to the PointLight's own metadata-defined Brightness/Range as the base.

local pointLight = script.Parent:WaitForChild("PointLight")

-- Flicker intensity, expressed as fractions of the CURRENT base (not hardcoded units).
-- Using fractions means the flicker amplitude scales correctly when LightingManager
-- dims us -- a dimmer campfire flickers proportionally less, not absolutely the same.
local BRIGHTNESS_FLICKER_PCT = 0.20  -- +/-20% of base
local RANGE_FLICKER_PCT      = 0.17  -- +/-17% of base

-- Smoothing factor for the lerp (0.1 = silky, 0.5 = jittery). 0.15 matches old behavior.
local SMOOTHING = 0.15

-- How often to pick a new random target (seconds).
local TARGET_CHANGE_TIME = 0.15

-- Initial fallback values: use whatever Brightness/Range the PointLight has at startup
-- (set via the model's metadata). These get superseded by AdjustedBrightness/AdjustedRange
-- once LightingManager processes us.
local fallbackBrightness = pointLight.Brightness
local fallbackRange = pointLight.Range

-- Reads the brightness the flicker should center on RIGHT NOW. Auto-leveled if available.
local function getBaseBrightness()
	local adjusted = pointLight:GetAttribute("AdjustedBrightness")
	if adjusted and adjusted > 0 then return adjusted end
	return fallbackBrightness
end

local function getBaseRange()
	local adjusted = pointLight:GetAttribute("AdjustedRange")
	if adjusted and adjusted > 0 then return adjusted end
	return fallbackRange
end

local currentBrightness = getBaseBrightness()
local currentRange = getBaseRange()
local targetBrightness = currentBrightness
local targetRange = currentRange
local timeSinceChange = 0

while true do
	local dt = task.wait()
	if not pointLight.Parent then break end -- campfire was destroyed
	timeSinceChange = timeSinceChange + dt

	-- Pick new random targets periodically, centered on the (possibly auto-leveled) base.
	if timeSinceChange >= TARGET_CHANGE_TIME then
		local baseB = getBaseBrightness()
		local baseR = getBaseRange()
		targetBrightness = baseB + (math.random() - 0.5) * 2 * baseB * BRIGHTNESS_FLICKER_PCT
		targetRange      = baseR + (math.random() - 0.5) * 2 * baseR * RANGE_FLICKER_PCT
		timeSinceChange = 0
	end

	-- Smoothly lerp toward targets.
	currentBrightness = currentBrightness + (targetBrightness - currentBrightness) * SMOOTHING
	currentRange = currentRange + (targetRange - currentRange) * SMOOTHING

	pointLight.Brightness = currentBrightness
	pointLight.Range = currentRange
end
