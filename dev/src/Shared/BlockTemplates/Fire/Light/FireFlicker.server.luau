-- FireFlicker for the Fire block's light.
--
-- IMPORTANT: This honors LightingManager's auto-leveling exactly like the
-- campfire's FireFlicker does. The PREVIOUS version of this script hardcoded its
-- own BASE_BRIGHTNESS and wrote Brightness/Range every frame WITHOUT registering
-- as a flicker light -- so LightingManager treated it as a normal light and
-- TWEENED Brightness at the same time this loop was writing it. Two writers on
-- the same property = the visible "fight"/jitter. The campfire never fought
-- because it (a) tags itself IsFlickerLight so the manager only writes ATTRIBUTES,
-- and (b) reads those attributes as its flicker base. This version does the same.
--
-- LightingManager sets these attributes on the PointLight when nearby lights
-- overlap:
--   AdjustedBrightness: the brightness this light should center on right now
--   AdjustedRange:      the range this light should center on right now
-- We read them each frame as the flicker base, so clustered fires dim and we
-- flicker around the dimmed value instead of blasting full brightness forever.

local pointLight = script.Parent:WaitForChild("PointLight")

-- Register with LightingManager as a flicker light so it auto-levels in clusters
-- and, crucially, does NOT tween this light directly (it writes attributes
-- instead). FlickerBaseBrightness/Range are the TRUE base values (the manager
-- reads these rather than a mid-flicker Brightness reading). Set from whatever
-- the PointLight is authored to in Studio, only if not already present.
if pointLight:GetAttribute("FlickerBaseBrightness") == nil then
	pointLight:SetAttribute("FlickerBaseBrightness", pointLight.Brightness)
end
if pointLight:GetAttribute("FlickerBaseRange") == nil then
	pointLight:SetAttribute("FlickerBaseRange", pointLight.Range)
end
pointLight:SetAttribute("IsFlickerLight", true)

-- Flicker intensity as fractions of the CURRENT base (not hardcoded units), so
-- the amplitude scales correctly when LightingManager dims us in a cluster.
local BRIGHTNESS_FLICKER_PCT = 0.20  -- +/-20% of base
local RANGE_FLICKER_PCT      = 0.17  -- +/-17% of base
local SMOOTHING = 0.15               -- 0.1 = silky, 0.5 = jittery
local TARGET_CHANGE_TIME = 0.15      -- seconds between new flicker targets

-- Fallbacks used until LightingManager has tracked us and set the Adjusted* attrs.
local fallbackBrightness = pointLight.Brightness
local fallbackRange = pointLight.Range

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
	if not pointLight.Parent then break end -- fire was extinguished
	timeSinceChange = timeSinceChange + dt

	-- Pick new random targets periodically, centered on the (possibly auto-leveled) base.
	if timeSinceChange >= TARGET_CHANGE_TIME then
		local baseB = getBaseBrightness()
		local baseR = getBaseRange()
		targetBrightness = baseB + (math.random() - 0.5) * 2 * baseB * BRIGHTNESS_FLICKER_PCT
		targetRange      = baseR + (math.random() - 0.5) * 2 * baseR * RANGE_FLICKER_PCT
		timeSinceChange = 0
	end

	currentBrightness = currentBrightness + (targetBrightness - currentBrightness) * SMOOTHING
	currentRange = currentRange + (targetRange - currentRange) * SMOOTHING

	pointLight.Brightness = currentBrightness
	pointLight.Range = currentRange
end