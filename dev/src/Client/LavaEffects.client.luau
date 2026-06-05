--[[
	LavaEffects
	Client-side visual effects for lava blocks.
	
	Handles:
	- Slow pulsing glow on the top surface (level 0/1 only)
	- Subtle transparency shimmer for "molten" feel
	- Brightness fade for deeper-flow lava (farther from source = dimmer)
	
	Mirrors WaterEffects.client.luau structurally so behavior stays
	predictable. Key differences:
		- NO height oscillation (lava is thick, not splashy)
		- Slower pulse speed than water shimmer
		- Tighter transparency range (lava stays mostly opaque)
		- Color shifts slightly toward dark red for distant flow
	
	Detection: IsLava attribute on a BasePart.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- Texture template loaded once. Cloned per face per lava block so each side
-- gets its own tinted Texture instance. Failing gracefully (nil) means lava
-- still renders, just without the texture overlay.
local LavaTextureTemplate = nil
task.spawn(function()
	local texturesFolder = ReplicatedStorage:WaitForChild("Textures", 10)
	if not texturesFolder then
		warn("[LavaEffects] ReplicatedStorage.Textures folder not found")
		return
	end
	local tex = texturesFolder:FindFirstChild("LavaTexture")
	if not tex then
		warn("[LavaEffects] Textures.LavaTexture not found")
		return
	end
	if not tex:IsA("Texture") then
		warn(string.format("[LavaEffects] Textures.LavaTexture is a %s, expected Texture", tex.ClassName))
		return
	end
	LavaTextureTemplate = tex
	print("[LavaEffects] Loaded LavaTexture template:", tex.Texture)
end)

local LAVA_FACES = { Enum.NormalId.Top, Enum.NormalId.Bottom, Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right }
local VERTICAL_FACES = { [Enum.NormalId.Front] = true, [Enum.NormalId.Back] = true, [Enum.NormalId.Left] = true, [Enum.NormalId.Right] = true }

-- Mirror LavaSystem's height-bucket math without requiring the module
-- on the client (avoids an extra require + cycle risk). MAX_LEVEL=4
-- gives HEIGHT_BUCKETS=5.
local LAVA_MAX_LEVEL = 4
local LAVA_HEIGHT_BUCKETS = LAVA_MAX_LEVEL + 1

local player = Players.LocalPlayer

-- Ember particle visual config. ColorSequence drifts from bright lava-yellow
-- to dark red as the spark cools. NumberSequence shrinks the size over its
-- lifetime so each ember pops then fades. Speed is upward with a touch of
-- randomness; Roblox's built-in gravity setting (Acceleration) pulls them
-- back down on a short arc.
local EMBER_COLOR_SEQ = ColorSequence.new({
	ColorSequenceKeypoint.new(0,    Color3.fromRGB(255, 220, 100)),
	ColorSequenceKeypoint.new(0.4,  Color3.fromRGB(255, 130, 30)),
	ColorSequenceKeypoint.new(1,    Color3.fromRGB(140, 30, 10)),
})
local EMBER_SIZE_SEQ = NumberSequence.new({
	NumberSequenceKeypoint.new(0,   0.35),
	NumberSequenceKeypoint.new(0.5, 0.25),
	NumberSequenceKeypoint.new(1,   0.05),
})
local EMBER_TRANSPARENCY_SEQ = NumberSequence.new({
	NumberSequenceKeypoint.new(0,   0.2),
	NumberSequenceKeypoint.new(0.7, 0.4),
	NumberSequenceKeypoint.new(1,   1.0),
})
local EMBER_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

-- ============================================
-- CONFIGURATION
-- ============================================

local PULSE_SPEED = 0.8             -- Slow pulse (water shimmer = 2.0)
local PULSE_AMOUNT = 0.0            -- Disabled: lava stays fully opaque
local BASE_TRANSPARENCY = 0.0       -- Fully opaque
local MAX_TRANSPARENCY = 0.0        -- Same opacity at all flow distances
local BRIGHT_COLOR = Color3.fromRGB(255, 90, 20)   -- Source / level 0
local DIM_COLOR    = Color3.fromRGB(230, 75, 18)   -- MAX_LEVEL (close to bright so the edge of the pool doesn't read as a hard color line)

-- Color pulse: each block's part color drifts back and forth between its
-- base color and a slightly dimmer version, like glowing/cooling embers.
-- COLOR_PULSE_SPEED is radians/sec on a sine wave (≈0.6 = ~10s full cycle
-- with the wrap-around). COLOR_PULSE_AMOUNT is how far toward dim the
-- color drifts at peak (0 = no pulse, 1 = swings all the way to DIM_COLOR).
-- A per-block phase offset is computed from world position so blocks pulse
-- out of sync, giving the lava pool a more organic shimmer.
local COLOR_PULSE_SPEED = 1.2
local COLOR_PULSE_AMOUNT = 0.45
local MAX_ANIMATED_LAVA = 200
local UPDATE_RANGE_SQ = (80 * 80)

-- Lava ember particles: occasionally a random lava block pops a tiny burst
-- of orange sparks. Tuned to feel ALIVE (a pool is always doing something)
-- without being a fireworks show. PARTICLE_CHECK_INTERVAL is how often the
-- particle loop runs; PARTICLE_EMITS_PER_TICK is how many blocks emit each
-- tick. With defaults, a visible pool produces roughly 6 sparks/second total
-- regardless of pool size.
local PARTICLE_CHECK_INTERVAL = 0.35
local PARTICLE_EMITS_PER_TICK = 2
local PARTICLE_RANGE_SQ = (60 * 60) -- only emit near the player; saves work

-- ============================================
-- STATE
-- ============================================

local animatedLava = {}
local animatedLavaList = {}
local lavaCount = 0

-- ============================================
-- LAVA DETECTION
-- ============================================

local function isLavaBlock(instance)
	return instance:IsA("BasePart") and instance:GetAttribute("IsLava") == true
end

local function getLavaLevel(part)
	return part:GetAttribute("LavaLevel") or 0
end

-- ============================================
-- ADD/REMOVE LAVA TRACKING
-- ============================================

local lavaConnections = {}

local function lerpColor(a, b, t)
	t = math.clamp(t, 0, 1)
	return Color3.new(
		a.R + (b.R - a.R) * t,
		a.G + (b.G - a.G) * t,
		a.B + (b.B - a.B) * t
	)
end

-- Derive the texture tint. Goal: the texture overlay should contrast against
-- BOTH the bright source AND the dim distant-flow lava, so it stays visible
-- on every block. We pick a fixed midpoint between BRIGHT_COLOR and DIM_COLOR,
-- which means:
--   - On bright source lava — texture reads slightly DARKER than the part
--   - On dim distant flow  — texture reads slightly BRIGHTER than the part
-- The tint is then scaled up by COMPENSATE so the Texture.Color3 multiply
-- against the orange image pixels doesn't crush it too dark.
local function deriveTextureTint(blockColor)
	local MID = Color3.new(
		(BRIGHT_COLOR.R + DIM_COLOR.R) * 0.5,
		(BRIGHT_COLOR.G + DIM_COLOR.G) * 0.5,
		(BRIGHT_COLOR.B + DIM_COLOR.B) * 0.5
	)
	local COMPENSATE = 1.6 -- Counters multiply-darkening from image pixels
	return Color3.new(
		math.min(MID.R * COMPENSATE, 1),
		math.min(MID.G * COMPENSATE, 1),
		math.min(MID.B * COMPENSATE, 1)
	)
end

-- (No longer used; kept for back-compat in case other code references it.)
local function lightenColor(c, amount)
	amount = math.clamp(amount, 0, 1)
	return Color3.new(
		c.R + (1 - c.R) * amount,
		c.G + (1 - c.G) * amount,
		c.B + (1 - c.B) * amount
	)
end

local TEXTURE_LIGHTEN = 0.45 -- (legacy constant, no longer used)

-- Build (or retrieve) the per-block ember ParticleEmitter. Rate=0 so it
-- never emits on its own; the global tick loop later calls :Emit(N) on
-- selected blocks for occasional bursts. Cached as a child Attachment so
-- it auto-cleans up when the part is destroyed.
local function ensureEmberEmitter(part)
	local existing = part:FindFirstChild("_LavaEmberAttach")
	if existing then
		local emitter = existing:FindFirstChildOfClass("ParticleEmitter")
		if emitter then return emitter end
	end
	
	local attach = Instance.new("Attachment")
	attach.Name = "_LavaEmberAttach"
	-- Position attachment at the top surface of the part. Part Size.Y/2 is
	-- the half-height; sitting the attachment slightly above the surface
	-- makes the emit point look right (otherwise sparks born inside the part).
	attach.Position = Vector3.new(0, part.Size.Y / 2 + 0.05, 0)
	attach.Parent = part
	
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "EmberEmitter"
	emitter.Texture = EMBER_TEXTURE
	emitter.Color = EMBER_COLOR_SEQ
	emitter.Size = EMBER_SIZE_SEQ
	emitter.Transparency = EMBER_TRANSPARENCY_SEQ
	emitter.LightEmission = 1   -- self-lit, looks glowy
	emitter.LightInfluence = 0  -- ignore world light
	emitter.Rate = 0            -- on-demand only; we'll call :Emit() ourselves
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Speed = NumberRange.new(4, 7)
	emitter.SpreadAngle = Vector2.new(25, 25)  -- mostly straight up, a little fan
	emitter.Acceleration = Vector3.new(0, -18, 0) -- gravity pulls them back down
	emitter.Drag = 1
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-90, 90)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Enabled = true       -- needed for :Emit() to work even with Rate=0
	emitter.Parent = attach
	
	return emitter
end

-- Build the 6 face textures on a lava part. One Texture per face, parented
-- DIRECTLY to the part (no wrapping folder — matches Roblox's standard
-- pattern for face-specific textures on blocks like the LavaBucket model).
-- Cached: refreshLavaVisuals updates tint / tile size without re-cloning.
local function ensureFaceTextures(part)
	if not LavaTextureTemplate then return nil end
	
	-- Migration: blow away any older _LavaTextures folder or single
	-- _LavaTexture from previous versions so we don't double-render.
	local oldFolder = part:FindFirstChild("_LavaTextures")
	if oldFolder then oldFolder:Destroy() end
	local oldSingle = part:FindFirstChild("_LavaTexture")
	if oldSingle then oldSingle:Destroy() end
	
	-- Look for existing per-face textures. We name them _LavaTex_<FaceName>
	-- so they're easy to find and don't collide with anything else on the part.
	local first = part:FindFirstChild("_LavaTex_Top")
	if first then
		-- Collect all 6 and return as a list
		local existing = {}
		for _, face in ipairs(LAVA_FACES) do
			local tex = part:FindFirstChild("_LavaTex_" .. face.Name)
			if tex then table.insert(existing, tex) end
		end
		return existing
	end
	
	local created = {}
	for _, face in ipairs(LAVA_FACES) do
		local tex = LavaTextureTemplate:Clone()
		tex.Face = face
		tex.Name = "_LavaTex_" .. face.Name
		tex.Parent = part
		table.insert(created, tex)
	end
	
	-- One-time log so we know textures are being applied. Remove when stable.
	if not _G._LavaTextureLogShown then
		_G._LavaTextureLogShown = true
		print(string.format("[LavaEffects] First textures applied on lava block (texture asset id: %s)", tostring(LavaTextureTemplate.Texture)))
	end
	return created
end

local function refreshLavaVisuals(part)
	local level = getLavaLevel(part)
	local isFalling = part:GetAttribute("IsFalling") or false
	local by = part:GetAttribute("BlockPosY")
	
	-- Compute correct height/Y offset from level so visuals don't depend
	-- on server replication landing first.
	local height
	if isFalling then
		height = BLOCK_SIZE
	else
		height = BLOCK_SIZE * (LAVA_HEIGHT_BUCKETS - level) / LAVA_HEIGHT_BUCKETS
	end
	
	local yOffset = -BLOCK_SIZE / 2 + height / 2
	
	if by then
		part:SetAttribute("_LavaOrigY", by + yOffset)
	else
		part:SetAttribute("_LavaOrigY", part.Position.Y)
	end
	part:SetAttribute("_LavaOrigHeight", height)
	
	part.Size = Vector3.new(BLOCK_SIZE, height, BLOCK_SIZE)
	if by then
		local bx = part:GetAttribute("BlockPosX") or part.Position.X
		local bz = part:GetAttribute("BlockPosZ") or part.Position.Z
		part.CFrame = CFrame.new(bx, by + yOffset, bz)
	end
	
	-- Level-based transparency + color (dimmer / redder when farther from source)
	local t = level / LAVA_MAX_LEVEL
	local transparency = BASE_TRANSPARENCY + (MAX_TRANSPARENCY - BASE_TRANSPARENCY) * t
	part.Transparency = transparency
	part:SetAttribute("_LavaBaseTransparency", transparency)
	
	local color = lerpColor(BRIGHT_COLOR, DIM_COLOR, t)
	part.Color = color
	part:SetAttribute("_LavaBaseColorR", color.R)
	part:SetAttribute("_LavaBaseColorG", color.G)
	part:SetAttribute("_LavaBaseColorB", color.B)
	
	-- Apply texture overlay: clone-once, then update tint + vertical tiling.
	-- Vertical tiling needs to match the part's actual height (flowing lava is
	-- shorter than a full block) so the texture doesn't squish or repeat ugly.
	-- Horizontal tiling stays at BLOCK_SIZE so the pattern reads as one tile
	-- per block when blocks sit side-by-side.
	local lavaTextures = ensureFaceTextures(part)
	if lavaTextures then
		local tintColor = deriveTextureTint(color)
		for _, tex in ipairs(lavaTextures) do
			tex.Color3 = tintColor
			tex.StudsPerTileU = BLOCK_SIZE
			if VERTICAL_FACES[tex.Face] then
				-- Side faces: V maps to height, so tile by the actual block
				-- height so flowing lava doesn't squish or repeat the pattern.
				tex.StudsPerTileV = height
			else
				-- Top/bottom: V maps to Z, always BLOCK_SIZE.
				tex.StudsPerTileV = BLOCK_SIZE
			end
		end
	end
	
	-- Update ember emitter attachment position when block size changes
	-- (flowing lava is shorter than a full block).
	local emitter = ensureEmberEmitter(part)
	if emitter then
		local attach = emitter.Parent
		if attach and attach:IsA("Attachment") then
			attach.Position = Vector3.new(0, height / 2 + 0.05, 0)
		end
	end
end

local function addLava(part)
	if animatedLava[part] then return end
	if lavaCount >= MAX_ANIMATED_LAVA then return end
	
	animatedLava[part] = true
	table.insert(animatedLavaList, part)
	lavaCount += 1
	
	refreshLavaVisuals(part)
	
	local conns = {}
	conns[1] = part:GetAttributeChangedSignal("LavaLevel"):Connect(function()
		if part and part.Parent then
			refreshLavaVisuals(part)
		end
	end)
	conns[2] = part:GetAttributeChangedSignal("IsFalling"):Connect(function()
		if part and part.Parent then
			refreshLavaVisuals(part)
		end
	end)
	lavaConnections[part] = conns
end

local function removeLava(part)
	if not animatedLava[part] then return end
	
	animatedLava[part] = nil
	lavaCount -= 1
	
	local conns = lavaConnections[part]
	if conns then
		for _, conn in ipairs(conns) do
			conn:Disconnect()
		end
		lavaConnections[part] = nil
	end
	
	for i = #animatedLavaList, 1, -1 do
		if animatedLavaList[i] == part then
			table.remove(animatedLavaList, i)
			break
		end
	end
end

-- ============================================
-- SCAN BUILD AREAS FOR LAVA
-- ============================================

local function scanForLava(folder)
	if not folder then return end
	
	for _, child in ipairs(folder:GetChildren()) do
		if isLavaBlock(child) then
			addLava(child)
		end
	end
end

local function watchFolder(folder)
	if not folder then return end
	
	scanForLava(folder)
	
	folder.ChildAdded:Connect(function(child)
		if isLavaBlock(child) then
			addLava(child)
		end
	end)
	
	folder.ChildRemoved:Connect(function(child)
		if animatedLava[child] then
			removeLava(child)
		end
	end)
end

local function setupWatchers()
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				watchFolder(blocksFolder)
			end
			buildArea.ChildAdded:Connect(function(child)
				if child.Name == "Blocks" and child:IsA("Folder") then
					watchFolder(child)
				end
			end)
		end
	end
	
	workspace.ChildAdded:Connect(function(child)
		if child.Name:match("^" .. GridConfig.BUILD_AREA_PREFIX .. "%d+$") then
			local blocksFolder = child:FindFirstChild("Blocks")
			if blocksFolder then
				watchFolder(blocksFolder)
			end
			child.ChildAdded:Connect(function(subChild)
				if subChild.Name == "Blocks" and subChild:IsA("Folder") then
					watchFolder(subChild)
				end
			end)
		end
	end)
	
	local megaPlot = workspace:FindFirstChild("MegaPlotBuildArea")
	if megaPlot then
		local blocksFolder = megaPlot:FindFirstChild("Blocks")
		if blocksFolder then
			watchFolder(blocksFolder)
		end
	end
end

-- ============================================
-- ANIMATION LOOP
-- ============================================

local elapsed = 0

RunService.Heartbeat:Connect(function(dt)
	if lavaCount == 0 then return end
	
	elapsed += dt
	
	local character = player.Character
	local playerPos = character and character:FindFirstChild("HumanoidRootPart")
	local playerPosition = playerPos and playerPos.Position or Vector3.zero
	
	for i = #animatedLavaList, 1, -1 do
		local part = animatedLavaList[i]
		
		if not part or not part.Parent then
			removeLava(part)
			continue
		end
		
		local delta = part.Position - playerPosition
		local distSq = delta.X * delta.X + delta.Z * delta.Z
		if distSq > UPDATE_RANGE_SQ then
			continue
		end
		
		-- Per-block phase offset so neighbors aren't in lockstep. Using
		-- position-based offset (not random) keeps the pulse stable across
		-- frames and looks like a slowly traveling shimmer.
		local spatialOffset = part.Position.X * 0.3 + part.Position.Z * 0.21
		-- sin output [-1, 1] -> remap to [0, 1] so the pulse always darkens
		-- the color, never brightens past base.
		local wave = (math.sin(elapsed * COLOR_PULSE_SPEED + spatialOffset) + 1) * 0.5
		local dimAmount = wave * COLOR_PULSE_AMOUNT
		
		local baseR = part:GetAttribute("_LavaBaseColorR")
		local baseG = part:GetAttribute("_LavaBaseColorG")
		local baseB = part:GetAttribute("_LavaBaseColorB")
		if baseR and baseG and baseB then
			-- Lerp from base color toward DIM_COLOR by dimAmount
			part.Color = Color3.new(
				baseR + (DIM_COLOR.R - baseR) * dimAmount,
				baseG + (DIM_COLOR.G - baseG) * dimAmount,
				baseB + (DIM_COLOR.B - baseB) * dimAmount
			)
		end
	end
end)

-- ============================================
-- EMBER PARTICLE TICK
-- ============================================
-- Separate from the per-frame color pulse so we only do this work a few
-- times per second. Picks PARTICLE_EMITS_PER_TICK random blocks from the
-- visible set and emits a 1-particle burst from each. Lazy: if there are
-- only a few blocks in view, fewer sparks happen naturally.

local particleTickAccum = 0

RunService.Heartbeat:Connect(function(dt)
	if lavaCount == 0 then return end
	particleTickAccum += dt
	if particleTickAccum < PARTICLE_CHECK_INTERVAL then return end
	particleTickAccum = 0
	
	local character = player.Character
	local playerPos = character and character:FindFirstChild("HumanoidRootPart")
	local playerPosition = playerPos and playerPos.Position or Vector3.zero
	
	-- Build a list of candidate blocks (visible, non-falling). We only
	-- emit from non-falling lava because falling streams already look busy
	-- and sparks on them would just smear sideways.
	local candidates = {}
	for i = 1, #animatedLavaList do
		local part = animatedLavaList[i]
		if part and part.Parent and not part:GetAttribute("IsFalling") then
			local delta = part.Position - playerPosition
			local distSq = delta.X * delta.X + delta.Z * delta.Z
			if distSq <= PARTICLE_RANGE_SQ then
				table.insert(candidates, part)
			end
		end
	end
	
	if #candidates == 0 then return end
	
	-- Pick N random candidates and emit one ember each
	for _ = 1, math.min(PARTICLE_EMITS_PER_TICK, #candidates) do
		local idx = math.random(1, #candidates)
		local part = candidates[idx]
		local attach = part:FindFirstChild("_LavaEmberAttach")
		if attach then
			local emitter = attach:FindFirstChildOfClass("ParticleEmitter")
			if emitter then
				emitter:Emit(1)
			end
		end
	end
end)

-- ============================================
-- INITIALIZE
-- ============================================

task.delay(2, function()
	setupWatchers()
	print("[LavaEffects] Initialized - watching for lava blocks")
end)
