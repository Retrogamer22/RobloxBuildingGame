-- BurntShatterParticles.client.luau
-- Client-side blocky particle burst for when a BURNT block shatters (e.g. a
-- charred block that fell too far, or a fragile burnt block that's broken).
-- The server fires Remotes.BurntShatterFX with { pos, size, color }; we spawn a
-- handful of small cubes that fly outward, fall under gravity, and fade out.
-- Style mirrors LeafParticleManager (anchored parts animated in a Heartbeat loop,
-- capped for performance, parented under Workspace.Terrain).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CONFIG = {
	-- How many cube shards per burst.
	SHARDS_MIN = 6,
	SHARDS_MAX = 10,
	-- Shard size as a fraction of the source block size (random within range).
	SHARD_SCALE_MIN = 0.12,
	SHARD_SCALE_MAX = 0.22,
	-- Initial outward/upward launch speed (studs/sec).
	LAUNCH_SPEED_MIN = 6,
	LAUNCH_SPEED_MAX = 14,
	UP_BIAS = 6,            -- extra upward kick so shards pop up before falling
	GRAVITY = 38,          -- studs/sec^2 pulling shards down
	SPIN_SPEED = 360,      -- max degrees/sec random tumble
	-- Lifetime + fade.
	LIFETIME_MIN = 0.5,
	LIFETIME_MAX = 0.9,
	FADE_FRACTION = 0.4,   -- last 40% of life is spent fading out
	-- Colour variation applied per shard (so the burst isn't flat).
	COLOR_VARIATION = 0.08,
	-- Performance cap on total live shards across all bursts.
	MAX_SHARDS = 120,
}

-- Container under Terrain (same as LeafParticleManager) so shards don't clutter
-- the block folders or get caught by the spatial index / save system.
local shardFolder = Instance.new("Folder")
shardFolder.Name = "BurntShatterShards"
shardFolder.Parent = Workspace.Terrain

local activeShards = {}  -- { part, vel, spinAxis, spinSpeed, startTime, lifetime }

local function vary(channel)
	return math.clamp(channel + (math.random() - 0.5) * 2 * CONFIG.COLOR_VARIATION, 0, 1)
end

local function spawnBurst(pos, size, color)
	if not pos then return end
	size = size or Vector3.new(3, 3, 3)
	color = color or Color3.fromRGB(40, 30, 25)

	local count = math.random(CONFIG.SHARDS_MIN, CONFIG.SHARDS_MAX)
	local baseDim = math.min(size.X, size.Y, size.Z)

	for _ = 1, count do
		if #activeShards >= CONFIG.MAX_SHARDS then break end

		local scale = CONFIG.SHARD_SCALE_MIN + math.random() * (CONFIG.SHARD_SCALE_MAX - CONFIG.SHARD_SCALE_MIN)
		local dim = math.max(0.2, baseDim * scale)

		local shard = Instance.new("Part")
		shard.Name = "BurntShard"
		shard.Shape = Enum.PartType.Block
		shard.Size = Vector3.new(dim, dim, dim)
		shard.Color = Color3.new(vary(color.R), vary(color.G), vary(color.B))
		shard.Material = Enum.Material.SmoothPlastic
		shard.Anchored = true
		shard.CanCollide = false
		shard.CanQuery = false
		shard.CanTouch = false
		shard.CastShadow = false

		-- Start near the block centre with a little random scatter.
		local jitter = Vector3.new(
			(math.random() - 0.5) * size.X * 0.5,
			(math.random() - 0.5) * size.Y * 0.5,
			(math.random() - 0.5) * size.Z * 0.5
		)
		shard.CFrame = CFrame.new(pos + jitter) * CFrame.Angles(
			math.rad(math.random(0, 360)),
			math.rad(math.random(0, 360)),
			math.rad(math.random(0, 360))
		)
		shard.Parent = shardFolder

		-- Random outward direction + upward bias.
		local dir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
		if dir.Magnitude < 0.05 then dir = Vector3.new(1, 0, 0) end
		dir = dir.Unit
		local speed = CONFIG.LAUNCH_SPEED_MIN + math.random() * (CONFIG.LAUNCH_SPEED_MAX - CONFIG.LAUNCH_SPEED_MIN)
		local vel = dir * speed + Vector3.new(0, CONFIG.UP_BIAS + math.random() * CONFIG.UP_BIAS, 0)

		local spinAxis = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
		if spinAxis.Magnitude < 0.05 then spinAxis = Vector3.new(0, 1, 0) end
		spinAxis = spinAxis.Unit

		table.insert(activeShards, {
			part = shard,
			vel = vel,
			spinAxis = spinAxis,
			spinSpeed = (math.random() - 0.5) * 2 * CONFIG.SPIN_SPEED,
			startTime = tick(),
			lifetime = CONFIG.LIFETIME_MIN + math.random() * (CONFIG.LIFETIME_MAX - CONFIG.LIFETIME_MIN),
		})
	end
end

RunService.Heartbeat:Connect(function(dt)
	if #activeShards == 0 then return end
	local now = tick()
	local toRemove = {}

	for i, s in ipairs(activeShards) do
		local part = s.part
		if not part or not part.Parent then
			table.insert(toRemove, i)
		else
			local age = now - s.startTime
			if age >= s.lifetime then
				table.insert(toRemove, i)
				part:Destroy()
			else
				-- Integrate velocity + gravity.
				s.vel = s.vel - Vector3.new(0, CONFIG.GRAVITY * dt, 0)
				local newPos = part.Position + s.vel * dt
				-- Tumble.
				local spin = CFrame.fromAxisAngle(s.spinAxis, math.rad(s.spinSpeed * dt))
				part.CFrame = (CFrame.new(newPos) * (part.CFrame - part.CFrame.Position)) * spin

				-- Fade out over the last FADE_FRACTION of life.
				local fadeStart = s.lifetime * (1 - CONFIG.FADE_FRACTION)
				if age > fadeStart then
					local f = (age - fadeStart) / (s.lifetime - fadeStart)
					part.Transparency = math.clamp(f, 0, 1)
				end
			end
		end
	end

	for i = #toRemove, 1, -1 do
		table.remove(activeShards, toRemove[i])
	end
end)

-- Connect to the server FX remote.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if Remotes then
	local fx = Remotes:WaitForChild("BurntShatterFX", 10)
	if fx then
		fx.OnClientEvent:Connect(function(data)
			if type(data) == "table" then
				spawnBurst(data.pos, data.size, data.color)
			end
		end)
		print("[BB-FIRE-FX] BurntShatterParticles connected")
	else
		warn("[BB-FIRE-FX] BurntShatterFX remote not found")
	end
end

-- Cleanup on leave.
Players.PlayerRemoving:Connect(function(p)
	if p == Players.LocalPlayer then
		for _, s in ipairs(activeShards) do
			if s.part and s.part.Parent then s.part:Destroy() end
		end
		activeShards = {}
		if shardFolder and shardFolder.Parent then shardFolder:Destroy() end
	end
end)