-- BlockBreakParticles.client.luau
-- Minecraft-style block-break burst. The server (BlockHandler) fires
-- Remotes.BlockBreakFX with { pos, size, color, material, materialVariant }
-- whenever a block/decoration is broken; we spawn a handful of small textured
-- chips that scatter from inside the block's volume, fall under gravity, bounce
-- and settle on the ground, then shrink and fade -- mimicking how Minecraft's
-- break particles behave (small textured squares contained in the block shape,
-- slightly darkened, gravity + ground collision, short life). [BB-BREAK-FX]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local CONFIG = {
	-- Minecraft spawns a bunch of small chips; keep them little and numerous.
	SHARDS_MIN = 14,
	SHARDS_MAX = 22,
	-- Chip size as a fraction of the block's smallest dimension.
	SHARD_SCALE_MIN = 0.07,
	SHARD_SCALE_MAX = 0.13,
	-- Gentle outward scatter + small upward pop. MC chips don't fly far; gravity
	-- pulls them down quickly and they settle on whatever's below.
	LAUNCH_SPEED_MIN = 2,
	LAUNCH_SPEED_MAX = 6,
	UP_BIAS = 5,
	GRAVITY = 52,
	-- Slight in-air tumble (MC particles are flat sprites; a gentle spin reads
	-- fine on the 3D chips). Stops once a chip lands.
	SPIN_SPEED = 160,
	-- Lifetime + tail animation.
	LIFETIME_MIN = 0.6,
	LIFETIME_MAX = 1.0,
	FADE_FRACTION = 0.35,    -- last 35% of life fades to transparent
	SHRINK_FRACTION = 0.3,   -- shrink over the last 30% of life
	-- Ground collision -- the key MC trait: chips land and rest.
	GROUND_BOUNCE = 0.3,     -- fraction of vertical speed kept on a bounce
	GROUND_FRICTION = 0.6,   -- horizontal speed kept after a ground hit
	GROUND_OFFSET = 0.04,    -- rest this far above the surface
	SETTLE_SPEED = 6,        -- below this downward speed, just settle (no bounce)
	-- Darken the chip vs the block, like MC's darker-face shading.
	DARKEN = 0.82,
	-- Per-chip colour jitter so the burst isn't flat.
	COLOR_VARIATION = 0.05,
	-- Performance cap on total live chips across all bursts.
	MAX_SHARDS = 200,
	-- Spawn the burst a touch above block centre so it reads a bit higher.
	SPAWN_LIFT = 0.3,
}

-- Container under Terrain so chips stay out of the block folders / spatial index
-- / save system (same as LeafParticleManager / BurntShatterParticles).
local shardFolder = Instance.new("Folder")
shardFolder.Name = "BlockBreakShards"
shardFolder.Parent = Workspace.Terrain

local activeShards = {}

-- Ground-detection ray: ignore our own chips (and the local character).
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.FilterDescendantsInstances = { shardFolder }

local function vary(channel)
	return math.clamp(channel + (math.random() - 0.5) * 2 * CONFIG.COLOR_VARIATION, 0, 1)
end

local function spawnBurst(pos, size, color, material, materialVariant)
	if not pos then return end
	size = size or Vector3.new(3, 3, 3)
	color = color or Color3.fromRGB(160, 160, 160)
	material = material or Enum.Material.SmoothPlastic

	-- Darken toward MC's shaded-face look.
	color = Color3.new(color.R * CONFIG.DARKEN, color.G * CONFIG.DARKEN, color.B * CONFIG.DARKEN)

	-- Lift the spawn origin a touch above centre.
	pos = pos + Vector3.new(0, size.Y * CONFIG.SPAWN_LIFT, 0)

	local count = math.random(CONFIG.SHARDS_MIN, CONFIG.SHARDS_MAX)
	local baseDim = math.min(size.X, size.Y, size.Z)

	for _ = 1, count do
		if #activeShards >= CONFIG.MAX_SHARDS then break end

		local scale = CONFIG.SHARD_SCALE_MIN + math.random() * (CONFIG.SHARD_SCALE_MAX - CONFIG.SHARD_SCALE_MIN)
		local dim = math.max(0.15, baseDim * scale)

		local shard = Instance.new("Part")
		shard.Name = "BreakShard"
		shard.Shape = Enum.PartType.Block
		shard.Size = Vector3.new(dim, dim, dim)
		shard.Color = Color3.new(vary(color.R), vary(color.G), vary(color.B))
		shard.Material = material
		if materialVariant and materialVariant ~= "" then
			shard.MaterialVariant = materialVariant
		end
		shard.Anchored = true
		shard.CanCollide = false
		shard.CanQuery = false
		shard.CanTouch = false
		shard.CastShadow = false

		-- Start somewhere inside the block's volume (MC keeps chips in the shape).
		local jitter = Vector3.new(
			(math.random() - 0.5) * size.X * 0.6,
			(math.random() - 0.5) * size.Y * 0.6,
			(math.random() - 0.5) * size.Z * 0.6
		)
		shard.CFrame = CFrame.new(pos + jitter) * CFrame.Angles(
			math.rad(math.random(0, 360)),
			math.rad(math.random(0, 360)),
			math.rad(math.random(0, 360))
		)
		shard.Parent = shardFolder

		-- Mostly-horizontal scatter with a small upward pop.
		local dir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
		if dir.Magnitude < 0.05 then dir = Vector3.new(1, 0, 0) end
		dir = dir.Unit
		local speed = CONFIG.LAUNCH_SPEED_MIN + math.random() * (CONFIG.LAUNCH_SPEED_MAX - CONFIG.LAUNCH_SPEED_MIN)
		local vel = dir * speed + Vector3.new(0, CONFIG.UP_BIAS * (0.5 + math.random() * 0.5), 0)

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
			baseSize = dim,
			grounded = false,
		})
	end
end

RunService.Heartbeat:Connect(function(dt)
	if #activeShards == 0 then return end
	local now = tick()
	local toRemove = {}

	-- Keep the local character out of the ground ray.
	local char = player.Character
	rayParams.FilterDescendantsInstances = char and { shardFolder, char } or { shardFolder }

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
				if not s.grounded then
					-- Integrate gravity + velocity.
					s.vel = s.vel - Vector3.new(0, CONFIG.GRAVITY * dt, 0)
					local curPos = part.Position
					local newPos = curPos + s.vel * dt

					-- Ground check: ray down over the step we're about to take, so
					-- the chip lands on whatever surface is below and rests.
					if s.vel.Y < 0 then
						local fall = (curPos.Y - newPos.Y) + s.baseSize
						local hit = Workspace:Raycast(curPos, Vector3.new(0, -fall, 0), rayParams)
						if hit then
							newPos = Vector3.new(newPos.X, hit.Position.Y + CONFIG.GROUND_OFFSET, newPos.Z)
							if math.abs(s.vel.Y) > CONFIG.SETTLE_SPEED then
								-- Small bounce + horizontal friction.
								s.vel = Vector3.new(
									s.vel.X * CONFIG.GROUND_FRICTION,
									-s.vel.Y * CONFIG.GROUND_BOUNCE,
									s.vel.Z * CONFIG.GROUND_FRICTION
								)
							else
								-- Slow enough -- settle and stop simulating.
								s.vel = Vector3.zero
								s.grounded = true
							end
						end
					end

					local spin = CFrame.fromAxisAngle(s.spinAxis, math.rad(s.spinSpeed * dt))
					part.CFrame = (CFrame.new(newPos) * (part.CFrame - part.CFrame.Position)) * spin
				end

				-- Fade out over the tail of the chip's life.
				local fadeStart = s.lifetime * (1 - CONFIG.FADE_FRACTION)
				if age > fadeStart then
					part.Transparency = math.clamp((age - fadeStart) / (s.lifetime - fadeStart), 0, 1)
				end

				-- Shrink over the tail too (MC chips change size as they expire).
				local shrinkStart = s.lifetime * (1 - CONFIG.SHRINK_FRACTION)
				if age > shrinkStart then
					local sf = 1 - ((age - shrinkStart) / (s.lifetime - shrinkStart)) * 0.6
					local d = math.max(0.05, s.baseSize * sf)
					part.Size = Vector3.new(d, d, d)
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
	local fx = Remotes:WaitForChild("BlockBreakFX", 10)
	if fx then
		fx.OnClientEvent:Connect(function(data)
			if type(data) == "table" then
				spawnBurst(data.pos, data.size, data.color, data.material, data.materialVariant)
			end
		end)
		print("[BB-BREAK-FX] BlockBreakParticles connected")
	else
		warn("[BB-BREAK-FX] BlockBreakFX remote not found")
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
