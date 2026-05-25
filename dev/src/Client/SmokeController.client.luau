-- SmokeController.client.luau
-- Client-side smoke particle simulation for campfires (and other smoke sources).
--
-- WHY CLIENT-SIDE:
-- The previous server-side SmokeManager replicated every particle position update
-- over the network, which made smoke feel choppy (~30 Hz tick + replication latency)
-- and ate bandwidth. Running this client-side means each player simulates their own
-- smoke at full framerate, using zero network bandwidth. The simulation is
-- intentionally random, so no player can tell that everyone is seeing slightly
-- different smoke -- it just looks like smoke.
--
-- BLOCK-ABOVE DETECTION STILL WORKS:
-- workspace:Raycast() works identically on the client. The client sees every block
-- the server has streamed in to it, so smoke caught under a block looks correct
-- locally. If a campfire is so far away that the block above it hasn't streamed in,
-- the player can't see the smoke clearly anyway, so this is a non-issue in practice.
--
-- COORDINATION WITH SERVER:
-- Campfires (and ColumnTorches if tagged) are still tagged "Campfire" by the
-- per-campfire server script (Smoke Particles.server.luau). Tags replicate
-- automatically, so this client controller just listens to CollectionService.
-- The SERVER SmokeManager.server.luau has been disabled -- it only kept the tag
-- system alive, which CollectionService handles natively anyway.

local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

-- ============================================
-- CONFIG (identical to the old SmokeManager so behavior matches exactly)
-- ============================================
local CONFIG = {
	MaxTotalParticles = 100,
	MaxParticlesPerSource = 15,
	BaseSpawnRate = 0.4,
	SpawnRadius = 0.8,
	SpawnHeight = 1.5,
	ParticleSize = Vector3.new(0.5, 0.5, 0.5),
	ParticleSizeVariation = 0.3,
	ParticleColor = Color3.fromRGB(180, 180, 180),
	ParticleTransparency = 0.4,
	RiseSpeed = 2,
	RiseSpeedVariation = 0.5,
	DriftSpeed = 0.3,
	WobbleAmount = 0.2,
	WobbleSpeed = 2,
	FreeLifetime = 8,
	CaughtLifetime = 3,
	FadeInTime = 0.3,
	FadeOutTime = 1.5,
	RaycastDistance = 1.0,
	CaughtOffset = 0.3,
	-- Note: no UpdateRate gate -- we run every Heartbeat for max smoothness.
	-- 100 particles * 60 Hz = 6000 raycasts/sec, negligible on modern Roblox.
}

local SMALL_SMOKE = {
	ParticleSize = Vector3.new(0.3, 0.3, 0.3),
	MaxParticles = 8,
	FreeLifetime = 4,
	RiseSpeed = 1.5,
	SpawnRadius = 0.4,
	GrowRate = 0.05,
}

local CAMPFIRE_TAG = "Campfire"

-- ============================================
-- STATE
-- ============================================
local registeredSources = {} -- [campfire] = sourceData
local activeParticles = {}   -- array of {Part, SourceData, SpawnTime, IsCaught, ...}
local particlePool = {}      -- pooled smoke parts for reuse

-- Particles live in a Folder under workspace. Parts created on the client are not
-- replicated to the server or other clients regardless of where they're parented,
-- so this is purely a cosmetic grouping. (Parenting to CurrentCamera caused render
-- issues in some setups; plain workspace is the boring safe choice.)
local particleContainer = nil
local function getParticleContainer()
	if particleContainer and particleContainer.Parent then return particleContainer end
	particleContainer = Instance.new("Folder")
	particleContainer.Name = "ClientSmokeParticles"
	particleContainer.Parent = Workspace
	return particleContainer
end

-- Raycast params: exclude all known campfires AND the local player's character
-- so smoke isn't caught by them. The character exclusion is new -- the old server
-- version didn't need it because the server isn't "a player", but client-side we
-- can walk over a campfire and we'd otherwise catch every particle.
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.FilterDescendantsInstances = {}

local function updateRaycastFilter()
	local excludeList = {}
	for campfire, _ in pairs(registeredSources) do
		if campfire and campfire.Parent then
			table.insert(excludeList, campfire)
		end
	end
	-- Also exclude the local player's character so the player walking over a fire
	-- doesn't catch every smoke particle the moment they're spawned.
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	if character then
		table.insert(excludeList, character)
	end
	-- And the particle container itself -- we don't want raycasts hitting other smoke.
	if particleContainer then
		table.insert(excludeList, particleContainer)
	end
	raycastParams.FilterDescendantsInstances = excludeList
end

-- Re-run the filter whenever the local character respawns
if Players.LocalPlayer then
	Players.LocalPlayer.CharacterAdded:Connect(updateRaycastFilter)
end

-- ============================================
-- PARTICLE PART POOLING
-- ============================================
local function createParticlePart()
	local part = Instance.new("Part")
	part.Name = "SmokeParticle"
	part.Shape = Enum.PartType.Block
	part.Material = Enum.Material.SmoothPlastic
	part.Color = CONFIG.ParticleColor
	part.Size = CONFIG.ParticleSize
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Anchored = true
	part.CastShadow = false
	return part
end

local function getParticle()
	if #particlePool > 0 then
		return table.remove(particlePool)
	end
	return createParticlePart()
end

local function returnParticle(particle)
	particle.Parent = nil
	particle.Transparency = 1
	table.insert(particlePool, particle)
end

-- ============================================
-- SPAWNING
-- ============================================
local function spawnParticle(campfire, sourceData)
	if #activeParticles >= CONFIG.MaxTotalParticles then return end
	local maxPer = sourceData.isSmall and SMALL_SMOKE.MaxParticles or CONFIG.MaxParticlesPerSource
	if sourceData.particleCount >= maxPer then return end

	local basePos
	local firePart = campfire:FindFirstChild("Fire")
	if firePart and firePart:IsA("BasePart") then
		basePos = firePart.Position
	else
		basePos = campfire:GetPivot().Position
	end

	local particleSize = sourceData.isSmall and SMALL_SMOKE.ParticleSize or CONFIG.ParticleSize
	local spawnRadius = sourceData.isSmall and SMALL_SMOKE.SpawnRadius or CONFIG.SpawnRadius
	local riseSpeed = sourceData.isSmall and SMALL_SMOKE.RiseSpeed or CONFIG.RiseSpeed

	local particle = getParticle()
	local sizeMultiplier = 1 + (math.random() - 0.5) * 2 * CONFIG.ParticleSizeVariation
	particle.Size = particleSize * sizeMultiplier
	particle.Position = basePos + Vector3.new(
		(math.random() - 0.5) * 2 * spawnRadius,
		CONFIG.SpawnHeight,
		(math.random() - 0.5) * 2 * spawnRadius
	)
	particle.Parent = getParticleContainer()

	sourceData.particleCount = sourceData.particleCount + 1

	table.insert(activeParticles, {
		Part = particle,
		SourceData = sourceData,
		SpawnTime = tick(),
		IsCaught = false,
		CaughtTime = nil,
		RiseSpeed = riseSpeed + (math.random() - 0.5) * 2 * CONFIG.RiseSpeedVariation,
		DriftX = (math.random() - 0.5) * 2 * CONFIG.DriftSpeed,
		DriftZ = (math.random() - 0.5) * 2 * CONFIG.DriftSpeed,
		WobbleOffset = math.random() * math.pi * 2,
		BaseSize = particle.Size,
	})
end

-- ============================================
-- PER-FRAME UPDATE
-- ============================================
local function update(dt)
	local currentTime = tick()

	-- Spawn new particles for each active source.
	for campfire, sourceData in pairs(registeredSources) do
		if not campfire.Parent then
			registeredSources[campfire] = nil
			updateRaycastFilter()
		elseif currentTime - sourceData.lastSpawn >= CONFIG.BaseSpawnRate then
			sourceData.lastSpawn = currentTime
			spawnParticle(campfire, sourceData)
		end
	end

	-- Update existing particles.
	for i = #activeParticles, 1, -1 do
		local data = activeParticles[i]
		local particle = data.Part
		local age = currentTime - data.SpawnTime
		local remove = false

		if data.IsCaught then
			local caughtAge = currentTime - data.CaughtTime
			if caughtAge >= CONFIG.CaughtLifetime then
				remove = true
			else
				local fadeStart = CONFIG.CaughtLifetime - CONFIG.FadeOutTime
				if caughtAge > fadeStart then
					particle.Transparency = CONFIG.ParticleTransparency + (1 - CONFIG.ParticleTransparency) * ((caughtAge - fadeStart) / CONFIG.FadeOutTime)
				end
				-- Slow rise + horizontal spread when caught under a block
				local wobble = math.sin(caughtAge * CONFIG.WobbleSpeed + data.WobbleOffset) * CONFIG.WobbleAmount
				particle.Position = particle.Position + Vector3.new(
					(data.DriftX + wobble) * dt,
					0.1 * dt,
					(data.DriftZ + wobble * 0.5) * dt
				)
			end
		else
			local isSmall = data.SourceData and data.SourceData.isSmall
			local freeLifetime = isSmall and SMALL_SMOKE.FreeLifetime or CONFIG.FreeLifetime
			if age >= freeLifetime then
				remove = true
			else
				-- Fade in/out envelope
				if age < CONFIG.FadeInTime then
					particle.Transparency = 1 - (1 - CONFIG.ParticleTransparency) * (age / CONFIG.FadeInTime)
				elseif age > freeLifetime - CONFIG.FadeOutTime then
					particle.Transparency = CONFIG.ParticleTransparency + (1 - CONFIG.ParticleTransparency) * ((age - (freeLifetime - CONFIG.FadeOutTime)) / CONFIG.FadeOutTime)
				else
					particle.Transparency = CONFIG.ParticleTransparency
				end

				-- Raycast upward to detect a block overhead
				local rayOrigin = particle.Position
				local rayDirection = Vector3.new(0, CONFIG.RaycastDistance, 0)
				local result = Workspace:Raycast(rayOrigin, rayDirection, raycastParams)

				local hitSolid = result
					and result.Instance:IsA("BasePart")
					and result.Instance.CanCollide
					and result.Instance.Name ~= "SmokeParticle"

				if hitSolid then
					-- Caught under a block: settle just below the hit surface and spread horizontally
					data.IsCaught = true
					data.CaughtTime = currentTime
					particle.Position = result.Position - Vector3.new(0, CONFIG.CaughtOffset, 0)
					data.DriftX = data.DriftX * 3
					data.DriftZ = data.DriftZ * 3
				else
					-- Normal rise + drift + wobble
					local wobble = math.sin(age * CONFIG.WobbleSpeed + data.WobbleOffset) * CONFIG.WobbleAmount
					particle.Position = particle.Position + Vector3.new(
						(data.DriftX + wobble) * dt,
						data.RiseSpeed * dt,
						(data.DriftZ + wobble * 0.5) * dt
					)
					local growRate = isSmall and SMALL_SMOKE.GrowRate or 0.1
					particle.Size = data.BaseSize * math.min(1 + age * growRate, 2)
				end
			end
		end

		if remove then
			if data.SourceData then
				data.SourceData.particleCount = math.max(0, data.SourceData.particleCount - 1)
			end
			returnParticle(particle)
			table.remove(activeParticles, i)
		end
	end
end

-- ============================================
-- REGISTRATION
-- ============================================
local function register(campfire)
	if registeredSources[campfire] then return end
	local blockType = campfire:GetAttribute("BlockType")
	local isSmall = (blockType == "ColumnTorch")
	registeredSources[campfire] = {
		lastSpawn = tick(),
		particleCount = 0,
		isSmall = isSmall,
	}
	print(string.format("[SmokeController] Registered campfire (isSmall=%s, total=%d)",
		tostring(isSmall), (function() local n=0 for _ in pairs(registeredSources) do n=n+1 end return n end)()))
	updateRaycastFilter()
end

local function unregister(campfire)
	registeredSources[campfire] = nil
	updateRaycastFilter()
end

-- ============================================
-- HOOK UP
-- ============================================
local initialTagged = CollectionService:GetTagged(CAMPFIRE_TAG)
print(string.format("[SmokeController] Found %d existing campfires at startup", #initialTagged))
for _, campfire in ipairs(initialTagged) do
	register(campfire)
end

CollectionService:GetInstanceAddedSignal(CAMPFIRE_TAG):Connect(register)
CollectionService:GetInstanceRemovedSignal(CAMPFIRE_TAG):Connect(unregister)

-- Heartbeat runs after physics, every frame. Particles run at full client framerate.
RunService.Heartbeat:Connect(update)

print("[SmokeController] Client-side smoke simulation initialized")
