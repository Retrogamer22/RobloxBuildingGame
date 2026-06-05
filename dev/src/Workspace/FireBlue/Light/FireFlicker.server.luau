-- FireLight flicker. Smooth, fire-like, and cluster-safe: the flicker only ever
-- dips BELOW the base values (never spikes above), and each fire gets its own
-- random phase, so a pile of fires averages to a steady glow instead of all
-- spiking white at once. Lower BASE_BRIGHTNESS if dense clusters still blow out.
local pointLight = script.Parent:WaitForChild("PointLight")

-- Base values = the BRIGHTEST this light ever gets. Flicker only goes down from here.
local BASE_BRIGHTNESS = 1.6   -- kept low on purpose; lights stack additively in clusters
local BASE_RANGE      = 16

-- How far DOWN from base the flicker dips (0..1 of the base). 0.25 = dips to 75% at most.
local BRIGHTNESS_DIP = 0.30
local RANGE_DIP      = 0.15

-- Smoothing toward each new target (higher = snappier, lower = smoother).
local SMOOTHING = 0.15
-- How often a new flicker target is picked.
local TARGET_CHANGE_TIME = 0.12

-- Per-fire random phase so neighbouring fires never flicker in lockstep.
local seed = math.random() * 1000

local currentBrightness = BASE_BRIGHTNESS
local currentRange = BASE_RANGE
local targetBrightness = BASE_BRIGHTNESS
local targetRange = BASE_RANGE
local timeSinceChange = 0
local clock = seed

while true do
	local dt = task.wait()
	clock += dt
	timeSinceChange += dt

	if timeSinceChange >= TARGET_CHANGE_TIME then
		-- math.random() is 0..1, so the dip is always subtractive: target sits
		-- between (base * (1 - dip)) and base. Never exceeds base -> no blow-out.
		targetBrightness = BASE_BRIGHTNESS * (1 - math.random() * BRIGHTNESS_DIP)
		targetRange      = BASE_RANGE      * (1 - math.random() * RANGE_DIP)
		timeSinceChange = 0
	end

	currentBrightness += (targetBrightness - currentBrightness) * SMOOTHING
	currentRange      += (targetRange - currentRange) * SMOOTHING

	pointLight.Brightness = currentBrightness
	pointLight.Range = currentRange
end