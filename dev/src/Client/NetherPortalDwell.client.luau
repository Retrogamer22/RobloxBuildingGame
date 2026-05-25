--[[
	NetherPortalDwell.client
	Watches whether the local player is standing inside a lit portal (via the
	existing _G.PortalVisionEffect.IsInside() the PortalVisionEffect script
	exposes). Once they've dwelled DWELL_SECONDS continuously, fires
	RequestNetherTravel to the server.

	After a teleport the server fires NetherTravelResult with an arrival grace;
	during that window we suppress dwell so the player doesn't instantly
	re-trigger on the return portal they arrive standing in.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local NetherConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("NetherConfig"))

local player = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RequestTravel = Remotes:WaitForChild(NetherConfig.REMOTE_REQUEST_TRAVEL)
local TravelResult = Remotes:WaitForChild(NetherConfig.REMOTE_TRAVEL_RESULT)

-- Per-client lighting per dimension.
--
-- Brightness. We fade global Brightness to 0 in the nether so the only
-- illumination is the player's own placed lights (torches, lanterns,
-- glowstone); on return we fade it back to whatever the overworld value was. We
-- CAPTURE the live overworld Brightness rather than hardcoding it, so retuning
-- it elsewhere can't desync this.
--
-- NOTE: GlobalShadows is intentionally NOT touched here. We used to force it OFF
-- in the overworld and ON in the nether, but that's been removed -- shadows are
-- now handled globally elsewhere, so this script leaves Lighting.GlobalShadows
-- exactly as the game sets it.
--
-- Brightness is set from a LocalScript, so it applies to THIS client only and
-- doesn't replicate -- safe to drive per-player.
local NETHER_BRIGHTNESS = 0
local LIGHTING_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Remembered overworld brightness. Seeded from the live value at startup (the
-- player always begins in the overworld), and re-captured on every overworld
-- arrival in case it changed while they were away.
local overworldBrightness = Lighting.Brightness

local brightnessTween = nil
local function tweenBrightnessTo(target)
	if brightnessTween then
		brightnessTween:Cancel()
		brightnessTween = nil
	end
	-- Skip if already there (avoids a pointless 0-length tween).
	if math.abs(Lighting.Brightness - target) < 0.001 then return end
	brightnessTween = TweenService:Create(Lighting, LIGHTING_TWEEN, { Brightness = target })
	brightnessTween:Play()
end

local function setDimensionLighting(dimension)
	if dimension == "nether" then
		-- Capture the overworld brightness we're leaving, so the return trip
		-- restores the correct value even if it was retuned since startup. Guard
		-- against capturing a mid-fade value if we somehow re-enter the nether.
		if Lighting.Brightness > NETHER_BRIGHTNESS + 0.001 then
			overworldBrightness = Lighting.Brightness
		end
		tweenBrightnessTo(NETHER_BRIGHTNESS)
	else
		tweenBrightnessTo(overworldBrightness)
	end
end

-- Player always starts in the overworld at full brightness (already captured
-- above into overworldBrightness, so nothing to tween here yet). GlobalShadows
-- is left untouched -- handled globally elsewhere now.

local dwellTime = 0          -- seconds continuously inside a portal
local graceUntil = 0         -- os.clock() time until which dwell is suppressed
local fired = false          -- already fired for this dwell; reset on exit

-- Server tells us to hold off (just teleported).
TravelResult.OnClientEvent:Connect(function(data)
	local grace = (type(data) == "table" and data.grace) or NetherConfig.ARRIVAL_GRACE_SECONDS
	graceUntil = os.clock() + grace
	dwellTime = 0
	fired = true   -- stay fired until they step out, so we don't re-trigger

	-- Switch per-client lighting to match the dimension we just arrived in.
	if type(data) == "table" and data.dimension then
		setDimensionLighting(data.dimension)
	end
end)

-- Reset on respawn.
player.CharacterAdded:Connect(function()
	dwellTime = 0
	fired = false
end)

local function isInsidePortal()
	local pve = _G.PortalVisionEffect
	if pve and pve.IsInside then
		return pve.IsInside() == true
	end
	return false
end

RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	local inside = isInsidePortal()

	if not inside then
		-- Stepped out: reset dwell + clear the fired latch so a fresh entry can
		-- trigger again.
		dwellTime = 0
		fired = false
		return
	end

	-- Inside a portal.
	if now < graceUntil then
		-- Arrival grace: don't accumulate dwell yet.
		dwellTime = 0
		return
	end

	if fired then
		-- Already fired for this continuous dwell; wait until they step out.
		return
	end

	dwellTime = dwellTime + dt
	if dwellTime >= NetherConfig.DWELL_SECONDS then
		fired = true
		dwellTime = 0
		RequestTravel:FireServer()
	end
end)

print(NetherConfig.LOG_PREFIX .. " NetherPortalDwell (client) initialized")
