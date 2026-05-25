-- BurntEmberDripParticles.client.luau
-- Client-side falling-ember "drip" for a hot charred block that's still cooling
-- AND floating in the air: little glowing embers crumble off its underside, fall
-- straight down under gravity, and fade out. Distinct from BurntShatterParticles
-- (which is an outward BURST when a block breaks) -- this is a gentle downward
-- drip while the block smoulders.
-- The server fires Remotes.BurntEmberDripFX with { pos, size, color }.
-- Style mirrors BurntShatterParticles / LeafParticleManager (anchored parts in a
-- Heartbeat loop, capped for perf, parented under Workspace.Terrain).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CONFIG = {
	-- How many embers crumble off per drip emission.
	EMBERS_MIN = 1,
	EMBERS_MAX = 3,
	-- Ember size as a fraction of the source block size (random within range).
	EMBER_SCALE_MIN = 0.06,
	EMBER_SCALE_MAX = 0.12,
	-- Gentle initial downward drift + a tiny sideways scatter (studs/sec). Unlike
	-- the shatter burst, these don't launch up -- they crumble and fall.
	SIDE_SCATTER = 1.5,    -- small random horizontal velocity
	DOWN_START = 1.0,      -- small initial downward nudge
	GRAVITY = 26,          -- studs/sec^2 pulling embers down (lighter than shards)
	SPIN_SPEED = 180,      -- max degrees/sec random tumble
	-- Lifetime + fade.
	LIFETIME_MIN = 0.7,
	LIFETIME_MAX = 1.3,
	FADE_FRACTION = 0.5,   -- last 50% of life is spent fading out
	-- Make embers glow: bias the colour toward hot orange and use Neon so they
	-- read as live embers rather than dull chips.
	GLOW = true,
	GLOW_COLOR = Color3.fromRGB(255, 120, 30), -- warm ember tint blended with block colour
	GLOW_BLEND = 0.5,                          -- how far toward GLOW_COLOR (0..1)
	COLOR_VARIATION = 0.1,
	-- Performance cap on total live embers across all drips.
	MAX_EMBERS = 150,
}

-- Container under Terrain (same as the shatter shards) so embers don't clutter
-- the block folders or get caught by the spatial index / save system.
local emberFolder = Instance.new("Folder")
emberFolder.Name = "BurntEmberDrips"
emberFolder.Parent = Workspace.Terrain

local activeEmbers = {}  -- { part, vel, spinAxis, spinSpeed, startTime, lifetime }

local function vary(channel)
	return math.clamp(channel + (math.random() - 0.5) * 2 * CONFIG.COLOR_VARIATION, 0, 1)
end

local function spawnDrip(pos, size, color)
	if not pos then return end
	size = size or Vector3.new(3, 3, 3)
	color = color or Color3.fromRGB(150, 60, 20)

	-- Blend toward the warm ember glow colour so the drips read as hot.
	if CONFIG.GLOW then
		color = color:Lerp(CONFIG.GLOW_COLOR, CONFIG.GLOW_BLEND)
	end

	local count = math.random(CONFIG.EMBERS_MIN, CONFIG.EMBERS_MAX)
	local baseDim = math.min(size.X, size.Y, size.Z)

	for _ = 1, count do
		if #activeEmbers >= CONFIG.MAX_EMBERS then break end

		local scale = CONFIG.EMBER_SCALE_MIN + math.random() * (CONFIG.EMBER_SCALE_MAX - CONFIG.EMBER_SCALE_MIN)
		local dim = math.max(0.15, baseDim * scale)

		local ember = Instance.new("Part")
		ember.Name = "BurntEmber"
		ember.Shape = Enum.PartType.Block
		ember.Size = Vector3.new(dim, dim, dim)
		ember.Color = Color3.new(vary(color.R), vary(color.G), vary(color.B))
		ember.Material = CONFIG.GLOW and Enum.Material.Neon or Enum.Material.SmoothPlastic
		ember.Anchored = true
		ember.CanCollide = false
		ember.CanQuery = false
		ember.CanTouch = false
		ember.CastShadow = false

		-- Start spread across the block's underside footprint (random X/Z within it).
		local jitter = Vector3.new(
			(math.random() - 0.5) * size.X * 0.7,
			(math.random() - 0.5) * size.Y * 0.15,
			(math.random() - 0.5) * size.Z * 0.7
		)
		ember.CFrame = CFrame.new(pos + jitter) * CFrame.Angles(
			math.rad(math.random(0, 360)),
			math.rad(math.random(0, 360)),
			math.rad(math.random(0, 360))
		)
		ember.Parent = emberFolder

		-- Mostly downward, with a little sideways scatter (no upward launch).
		local vel = Vector3.new(
			(math.random() - 0.5) * 2 * CONFIG.SIDE_SCATTER,
			-CONFIG.DOWN_START * math.random(),
			(math.random() - 0.5) * 2 * CONFIG.SIDE_SCATTER
		)

		local spinAxis = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
		if spinAxis.Magnitude < 0.05 then spinAxis = Vector3.new(0, 1, 0) end
		spinAxis = spinAxis.Unit

		table.insert(activeEmbers, {
			part = ember,
			vel = vel,
			spinAxis = spinAxis,
			spinSpeed = (math.random() - 0.5) * 2 * CONFIG.SPIN_SPEED,
			startTime = tick(),
			lifetime = CONFIG.LIFETIME_MIN + math.random() * (CONFIG.LIFETIME_MAX - CONFIG.LIFETIME_MIN),
		})
	end
end

RunService.Heartbeat:Connect(function(dt)
	if #activeEmbers == 0 then return end
	local now = tick()
	local toRemove = {}

	for i, e in ipairs(activeEmbers) do
		local part = e.part
		if not part or not part.Parent then
			table.insert(toRemove, i)
		else
			local age = now - e.startTime
			if age >= e.lifetime then
				table.insert(toRemove, i)
				part:Destroy()
			else
				-- Integrate velocity + gravity.
				e.vel = e.vel - Vector3.new(0, CONFIG.GRAVITY * dt, 0)
				local newPos = part.Position + e.vel * dt
				-- Tumble.
				local spin = CFrame.fromAxisAngle(e.spinAxis, math.rad(e.spinSpeed * dt))
				part.CFrame = (CFrame.new(newPos) * (part.CFrame - part.CFrame.Position)) * spin

				-- Fade out over the last FADE_FRACTION of life.
				local fadeStart = e.lifetime * (1 - CONFIG.FADE_FRACTION)
				if age > fadeStart then
					local f = (age - fadeStart) / (e.lifetime - fadeStart)
					part.Transparency = math.clamp(f, 0, 1)
				end
			end
		end
	end

	for i = #toRemove, 1, -1 do
		table.remove(activeEmbers, toRemove[i])
	end
end)

-- Connect to the server FX remote.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if Remotes then
	local fx = Remotes:WaitForChild("BurntEmberDripFX", 10)
	if fx then
		fx.OnClientEvent:Connect(function(data)
			if type(data) == "table" then
				spawnDrip(data.pos, data.size, data.color)
			end
		end)
		print("[BB-FIRE-FX] BurntEmberDripParticles connected")
	else
		warn("[BB-FIRE-FX] BurntEmberDripFX remote not found")
	end
end

-- Cleanup on leave.
Players.PlayerRemoving:Connect(function(p)
	if p == Players.LocalPlayer then
		for _, e in ipairs(activeEmbers) do
			if e.part and e.part.Parent then e.part:Destroy() end
		end
		activeEmbers = {}
		if emberFolder and emberFolder.Parent then emberFolder:Destroy() end
	end
end)