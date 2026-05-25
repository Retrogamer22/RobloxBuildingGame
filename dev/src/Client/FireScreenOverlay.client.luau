--[[
	FireScreenOverlay.client.luau

	Minecraft-style "you're on fire" screen overlay. When the local player is
	standing in a Fire block, an animated flame strip appears across the BOTTOM of
	the screen (full width, partial height) cycling through the 16 flame frames.
	Stepping out of the fire fades it back away.

	Structure mirrors PortalVisionEffect.client.luau:
	  - Watches every plot's Blocks folder (+ MegaPlot + Nether) for parts carrying
	    the IsFire attribute, keeping a live set (attribute-based, so it doesn't
	    depend on the fire part's collision geometry).
	  - Probes at 20 Hz whether the player's root is within a fire's cell.
	  - That boolean drives a 0..1 `intensity` that eases in fast / out slower.
	  - `intensity` fades the overlay's transparency; a separate frame timer cycles
	    the flame image regardless of intensity so it's already animating when it
	    fades in.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local NetherConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("NetherConfig", 10))
local BLOCK_SIZE = GridConfig.BLOCK_SIZE

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = Workspace.CurrentCamera

-- ============================================
-- CONFIGURATION
-- ============================================

local DEBUG_FIRE_FX = false  -- verbose enter/exit + fire-count logs

local PROBE_INTERVAL = 0.05  -- seconds between inside-checks (20 Hz)

-- How close the player's root must be to a fire's cell centre to count as "in
-- fire". Fire occupies the cell ABOVE its support; the player stands in that
-- cell. Roomy tolerances so it reads reliably while you're standing in the
-- flames rather than dead-centre.
local HORIZONTAL_TOLERANCE = BLOCK_SIZE * 0.6  -- ~1.8 studs each side
local VERTICAL_TOLERANCE = BLOCK_SIZE * 0.9    -- ~2.7 studs up/down (covers legs+torso in the cell)

-- Fade speeds (intensity units/sec). Snappy in, slower out.
local FADE_IN_SPEED = 6.0   -- ~0.17s to full
local FADE_OUT_SPEED = 3.0  -- ~0.33s to clear

-- Overlay geometry. The flame fills the full screen WIDTH at its NATURAL aspect
-- ratio (Crop = no squish), and we slide it DOWN so the flames sit low on the
-- screen with their top cropping off above. The band is full-screen so the
-- cropping is done by the screen edges.
--   OVERLAY_DOWN_SHIFT: how far (in screen-height fractions) to push the image
--   down. 0 = centred; higher = lower on screen (more of the bottom runs off).
local OVERLAY_DOWN_SHIFT = 0.55   -- slide the flames down toward the bottom
local MAX_OVERLAY_ALPHA = 0.0     -- ImageTransparency when shown (0 = fully opaque)

-- How the (low-res) flame frames are upscaled across the screen. The frames are
-- small pixel-art textures, so stretching them big is inherently blocky -- this
-- only controls the SCALING STYLE, not the source detail (for genuinely more
-- detail you'd need higher-res frame uploads):
--   Default   = bilinear smoothing (softens the blockiness; looks less "pixely")
--   Pixelated = crisp hard pixel edges (true pixel-art look; emphasises blocks)
local FLAME_RESAMPLE = Enum.ResamplerMode.Pixelated

-- FIRST-PERSON ONLY: hide the overlay unless the camera is essentially at the
-- player's head (first person). We measure the distance from the camera to the
-- head; in first person it's ~0.5 studs, in third person it's several studs out.
local FIRST_PERSON_MAX_DISTANCE = 2.0  -- studs; <= this counts as first person

-- Flame animation: the 16 frames you provided, cycled at FRAME_DELAY each.
local FRAMES = {
	"rbxassetid://104477729534662",
	"rbxassetid://140652547151411",
	"rbxassetid://103383594087156",
	"rbxassetid://87303781883558",
	"rbxassetid://96241542227380",
	"rbxassetid://108394388696766",
	"rbxassetid://96720916046645",
	"rbxassetid://89249481377584",
	"rbxassetid://75644616473701",
	"rbxassetid://113861573469546",
	"rbxassetid://114154707733329",
	"rbxassetid://115376306601555",
	"rbxassetid://105562044039834",
	"rbxassetid://124080693162472",
	"rbxassetid://98128562930475",
	"rbxassetid://118749462886422",
}
local FRAME_DELAY = 0.1  -- seconds per frame (matches the world FireAnimation)

-- ============================================
-- OVERLAY UI
-- ============================================

local gui = Instance.new("ScreenGui")
gui.Name = "FireScreenOverlay"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 50  -- above the world / most HUD, but tune if it covers something important
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Enabled = false
gui.Parent = playerGui

-- Clipping container: full-screen, clips anything outside it. The flame image
-- inside fills the width at natural aspect (Crop) and is slid DOWN, so its top
-- crops off at the top of the screen and the flames sit low.
local band = Instance.new("Frame")
band.Name = "FlameBand"
band.BackgroundTransparency = 1
band.AnchorPoint = Vector2.new(0.5, 1)
band.Position = UDim2.fromScale(0.5, 1)            -- pinned to bottom of screen
band.Size = UDim2.fromScale(1, 1)                  -- full screen; clip at screen edges
band.ClipsDescendants = true
band.Parent = gui

-- The flame image: fills the full screen at NATURAL aspect (Crop = no squish),
-- then slid DOWN by OVERLAY_DOWN_SHIFT so the flames sit low and the top crops
-- off above. Crop preserves aspect ratio and trims overflow -- never stretches.
local flame = Instance.new("ImageLabel")
flame.Name = "FlameStrip"
flame.BackgroundTransparency = 1
flame.AnchorPoint = Vector2.new(0.5, 0.5)
flame.Position = UDim2.fromScale(0.5, 0.5 + OVERLAY_DOWN_SHIFT)  -- centred, then pushed down
flame.Size = UDim2.fromScale(1, 1)                 -- fill the band (Crop keeps aspect)
flame.Image = FRAMES[1]
flame.ImageTransparency = 1
flame.ScaleType = Enum.ScaleType.Crop              -- fill width at natural aspect, crop overflow (no squish)
flame.ResampleMode = FLAME_RESAMPLE                -- scaling style (smooth vs pixelated)
flame.Parent = band

-- ============================================
-- FIRE PART TRACKING (PortalVisionEffect-style watcher)
-- ============================================

local fireParts = {}   -- set: part -> true
local fireList = {}    -- ordered for iteration

local function isFirePart(inst)
	return inst:GetAttribute("IsFire") == true
end

local function addFire(inst)
	if fireParts[inst] then return end
	fireParts[inst] = true
	table.insert(fireList, inst)
	if DEBUG_FIRE_FX then
		print(string.format("[BB-FIRE-FX] +fire (now %d)", #fireList))
	end
end

local function removeFire(inst)
	if not fireParts[inst] then return end
	fireParts[inst] = nil
	for i = #fireList, 1, -1 do
		if fireList[i] == inst then
			table.remove(fireList, i)
			break
		end
	end
	if DEBUG_FIRE_FX then
		print(string.format("[BB-FIRE-FX] -fire (now %d)", #fireList))
	end
end

-- A Fire is a Model (with the IsFire attribute on the model). Track the model
-- itself; we read its grid centre from its BlockPos attributes, so we don't need
-- its parts. Also handle the BasePart case defensively.
local function tryAdd(child)
	if isFirePart(child) then
		addFire(child)
	end
end

local function watchFolder(folder)
	if not folder then return end
	for _, child in ipairs(folder:GetChildren()) do
		tryAdd(child)
	end
	folder.ChildAdded:Connect(tryAdd)
	folder.ChildRemoved:Connect(function(child)
		if fireParts[child] then
			removeFire(child)
		end
	end)
end

local function watchBuildArea(buildArea)
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

local function setupWatchers()
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = Workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			watchBuildArea(buildArea)
		end
	end

	Workspace.ChildAdded:Connect(function(child)
		if child.Name:match("^" .. GridConfig.BUILD_AREA_PREFIX .. "%d+$")
			or child.Name:match("^" .. NetherConfig.NETHER_PLOT_PREFIX .. "%d+$") then
			watchBuildArea(child)
		end
	end)

	for i = 1, GridConfig.TOTAL_PLOTS do
		local netherPlot = Workspace:FindFirstChild(NetherConfig.NETHER_PLOT_PREFIX .. i)
		if netherPlot then
			watchBuildArea(netherPlot)
		end
	end

	local megaRoom = Workspace:FindFirstChild("MegaPlotRoom")
	local megaArea = (megaRoom and megaRoom:FindFirstChild("MegaPlotBuildArea"))
		or Workspace:FindFirstChild("MegaPlotBuildArea")
	if megaArea then
		watchBuildArea(megaArea)
	end
	if megaRoom then
		megaRoom.ChildAdded:Connect(function(child)
			if child.Name == "MegaPlotBuildArea" then
				watchBuildArea(child)
			end
		end)
	end
end

-- ============================================
-- STATE
-- ============================================

local intensity = 0
local inFire = false
local timeSinceProbe = 0
local frameTimer = 0
local frameIndex = 1

-- ============================================
-- INSIDE CHECK
-- ============================================

-- The fire's grid centre comes from its BlockPos attributes (the cell it fills,
-- above its support). True if the player root is within that cell's tolerances.
local function posInFire(pos, fireInst)
	local cx = fireInst:GetAttribute("BlockPosX")
	local cy = fireInst:GetAttribute("BlockPosY")
	local cz = fireInst:GetAttribute("BlockPosZ")
	if not (cx and cy and cz) then return false end

	return math.abs(pos.X - cx) <= HORIZONTAL_TOLERANCE
		and math.abs(pos.Z - cz) <= HORIZONTAL_TOLERANCE
		and math.abs(pos.Y - cy) <= VERTICAL_TOLERANCE
end

local function probeInFire()
	if #fireList == 0 then return false end
	local character = player.Character
	if not character then return false end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	local pos = root.Position

	for i = #fireList, 1, -1 do
		local inst = fireList[i]
		if not inst or not inst.Parent then
			removeFire(inst)
		elseif posInFire(pos, inst) then
			return true
		end
	end
	return false
end

-- First person = camera is essentially at the player's head. In third person the
-- camera sits several studs back, so the head-to-camera distance jumps. We use
-- that distance as the test (no reliance on CameraMode, which players can change).
local function isFirstPerson()
	if not camera then return false end
	local character = player.Character
	if not character then return false end
	local head = character:FindFirstChild("Head")
	if not head then return false end
	local dist = (camera.CFrame.Position - head.Position).Magnitude
	return dist <= FIRST_PERSON_MAX_DISTANCE
end

-- ============================================
-- MAIN LOOP
-- ============================================

RunService.RenderStepped:Connect(function(dt)
	-- Keep our camera reference current (it's replaced on respawn).
	camera = Workspace.CurrentCamera

	-- Cycle the flame frames continuously (so it's mid-animation when it appears).
	frameTimer += dt
	if frameTimer >= FRAME_DELAY then
		frameTimer -= FRAME_DELAY
		frameIndex = frameIndex % #FRAMES + 1
		flame.Image = FRAMES[frameIndex]
	end

	-- Probe whether we're standing in fire (throttled).
	timeSinceProbe += dt
	if timeSinceProbe >= PROBE_INTERVAL then
		timeSinceProbe = 0
		local wasIn = inFire
		-- First-person only: even when standing in fire, don't show the overlay if
		-- the camera is zoomed out to third person.
		inFire = probeInFire() and isFirstPerson()
		if DEBUG_FIRE_FX and inFire ~= wasIn then
			print("[BB-FIRE-FX] overlay " .. (inFire and "ENTER" or "EXIT"))
		end
	end

	-- Snap the overlay ON/OFF instantly with `inFire` (no fade). Either fully
	-- opaque flames while standing in fire, or hidden the moment you step out.
	if inFire then
		if not gui.Enabled then gui.Enabled = true end
		flame.ImageTransparency = MAX_OVERLAY_ALPHA
	else
		if gui.Enabled then gui.Enabled = false end
	end
end)

player.CharacterAdded:Connect(function()
	inFire = false
	intensity = 0
	gui.Enabled = false
	flame.ImageTransparency = 1
end)

-- Delay so build areas / loaded saves are present, then start watching.
task.delay(2, function()
	setupWatchers()
	if DEBUG_FIRE_FX then
		print(string.format("[BB-FIRE-FX] FireScreenOverlay initialized (%d fire parts tracked)", #fireList))
	end
end)