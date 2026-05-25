--[[
	PortalVisionEffect.client.luau

	Minecraft-style "inside the portal" screen effect. When the local player is
	standing inside a lit portal (any block carrying the IsPortal attribute), their
	vision tints with that portal's colour and warps slightly. Stepping out fades
	the effect back to normal. The colour is read per-portal from the part's
	PortalTint attribute (set server-side from the frame material), so different
	dimensions tint the screen differently -- purple nether, future cyan ice, etc.

	How it works:
	  - It keeps a live set of portal parts by watching every plot's Blocks
	    folder (+ MegaPlot), the same watcher pattern WaterEffects uses. This is
	    attribute-based, so it does NOT depend on the portal part's CanQuery flag
	    or its (very thin, 0.40-stud) collision geometry -- both of which make a
	    GetPartBoundsInBox probe unreliable for portal sheets.
	  - Every probe tick it checks whether the player's torso is within the
	    portal's cell: full block tolerance on the two "wide" axes, and a roomier
	    tolerance on the thin axis so you reliably read as "inside" while standing
	    in the opening.
	  - That boolean drives a single 0..1 `intensity` value that eases toward 1
	    while inside and toward 0 while outside (asymmetric speeds: snappy fade-in
	    like stepping into the haze, slower fade-out as it clears).
	  - `intensity` is applied each frame to a DEDICATED set of Lighting effects
	    this script owns (PVE_ prefix). It never touches the day/night cycle's own
	    ColorCorrectionEffect, so the two compose instead of fighting.

	Effects driven:
	  - ColorCorrectionEffect  -> purple TintColor + saturation/contrast push
	  - DepthOfFieldEffect     -> soft "warp"/blur at the edges of vision
	  - A full-screen purple ScreenGui vignette (sells the tint where post
	    effects are weak / disabled)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local NetherConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("NetherConfig", 10))
local BLOCK_SIZE = GridConfig.BLOCK_SIZE

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ============================================
-- CONFIGURATION
-- ============================================

local DEBUG_PORTAL_FX = false  -- [BB-PORTAL] verbose enter/exit + portal-count logs

local PROBE_INTERVAL = 0.05    -- seconds between inside-checks (20 Hz)

-- Inside tolerances. The portal sheet is thin (~0.4 studs) but the OPENING it
-- fills is a full block, so we test against the cell, not the part geometry:
--   wide axes  -> half a block of slack (you're inside the 3x3 opening)
--   thin axis  -> a bit over a full block, so you read "inside" even though your
--                 torso is offset from the paper-thin sheet.
local WIDE_TOLERANCE = BLOCK_SIZE * 0.55   -- ~1.65 studs each side
local THIN_TOLERANCE = BLOCK_SIZE * 0.7    -- ~2.1 studs each side
local VERTICAL_TOLERANCE = BLOCK_SIZE * 0.6 -- ~1.8 studs up/down within the cell

-- Fade speeds (intensity units per second). Fade-in quicker than fade-out.
local FADE_IN_SPEED = 4.0      -- ~0.25s to full
local FADE_OUT_SPEED = 1.8     -- ~0.55s to clear

-- Look at full intensity.
-- DEFAULT_TINT is the fallback used when a portal block has no PortalTint
-- attribute (e.g. very old saves). Each portal block now carries its own
-- PortalTint (set server-side from the frame material), so the vision colour
-- matches whatever dimension you're standing in -- purple nether, future cyan
-- ice, etc. The active colour is read from the part you're inside.
local DEFAULT_TINT = Color3.fromRGB(140, 70, 220)   -- purple (nether)
local TINT_LERP_SPEED = 6.0    -- how fast the screen colour eases to a new portal's colour
local MAX_TINT_BLEND = 0.65
local MAX_SATURATION = 0.35
local MAX_CONTRAST = 0.10
local MAX_BRIGHTNESS = -0.04
local MAX_DOF_INTENSITY = 0.20
local MAX_BLUR_SIZE = 14        -- BlurEffect.Size at full intensity. This is the
                               -- real "swimming vision" blur -- a flat full-screen
                               -- Gaussian that works regardless of depth (unlike
                               -- DOF, which needs something close to the camera).
local MAX_VIGNETTE_ALPHA = 0.45

-- Full-screen swirl overlay. The portal's swirl image is stretched over the
-- whole screen and ramps from invisible up to MAX_SWIRL_ALPHA opacity as dwell
-- (intensity) builds -- the "the portal is pulling you in" effect. The whole
-- image is used as-is (not frame-animated) and tints with currentTint to match
-- the dimension.
local SWIRL_SHEET = "rbxassetid://134059001370245"
local MAX_SWIRL_ALPHA = 0.60   -- peak opacity at full dwell (0.60 = 60% opaque)
local SWIRL_RAMP_SPEED = 0.6   -- how fast the swirl opacity builds, in units/sec.
                               -- Separate from the tint/wobble fade so the swirl
                               -- can creep in slowly while they come in fast.
                               -- ~1.7s to reach full from a cold start; lower =
                               -- slower. Fades back out at the same rate.

-- ============================================
-- OWNED LIGHTING EFFECTS (PVE_ = PortalVisionEffect)
-- ============================================

local cc = Instance.new("ColorCorrectionEffect")
cc.Name = "PVE_ColorCorrection"
cc.Enabled = false
cc.TintColor = Color3.new(1, 1, 1)
cc.Saturation = 0
cc.Contrast = 0
cc.Brightness = 0
cc.Parent = Lighting

local dof = Instance.new("DepthOfFieldEffect")
dof.Name = "PVE_DepthOfField"
dof.Enabled = false
dof.FarIntensity = 0
dof.NearIntensity = 0
dof.FocusDistance = 5
dof.InFocusRadius = 10
dof.Parent = Lighting

-- Flat full-screen Gaussian blur. This is the effect that actually reads as
-- "blurry portal vision" in a first-person building view -- DOF needs geometry
-- near the camera to blur against, BlurEffect just blurs the whole frame.
local blur = Instance.new("BlurEffect")
blur.Name = "PVE_Blur"
blur.Enabled = false
blur.Size = 0
blur.Parent = Lighting

-- ============================================
-- VIGNETTE OVERLAY
-- ============================================

local gui = Instance.new("ScreenGui")
gui.Name = "PortalVisionOverlay"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = -5
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Enabled = false
gui.Parent = playerGui

local vignette = Instance.new("ImageLabel")
vignette.Name = "Vignette"
vignette.BackgroundTransparency = 1
vignette.Size = UDim2.fromScale(1, 1)
vignette.Image = "rbxassetid://5181534211" -- radial gradient: clear center, solid edges
vignette.ImageColor3 = DEFAULT_TINT
vignette.ImageTransparency = 1
vignette.ScaleType = Enum.ScaleType.Stretch
vignette.ZIndex = 2   -- vignette darkening sits ON TOP of the swirl overlay
vignette.Parent = gui

-- Full-screen swirl: the portal's image stretched across the whole screen,
-- ramping from invisible to MAX_SWIRL_ALPHA opacity as dwell builds. Sits BELOW
-- the vignette (ZIndex 1 < 2) so the edge-darkening reads over it. Tinted with
-- currentTint to match the dimension.
local swirl = Instance.new("ImageLabel")
swirl.Name = "SwirlOverlay"
swirl.BackgroundTransparency = 1
swirl.Size = UDim2.fromScale(1, 1)
swirl.Image = SWIRL_SHEET
swirl.ImageColor3 = DEFAULT_TINT
swirl.ImageTransparency = 1
swirl.ScaleType = Enum.ScaleType.Crop   -- cover-style: fill screen uniformly, clip overflow (no squish)
swirl.ZIndex = 1
swirl.Parent = gui

-- ============================================
-- PORTAL PART TRACKING (WaterEffects-style watcher)
-- ============================================

local portalParts = {}   -- set: part -> true
local portalList = {}    -- ordered for iteration

local function isPortalPart(inst)
	return inst:IsA("BasePart") and inst:GetAttribute("IsPortal") == true
end

local function addPortal(part)
	if portalParts[part] then return end
	portalParts[part] = true
	table.insert(portalList, part)
	if DEBUG_PORTAL_FX then
		print(string.format("[BB-PORTAL] +portal (now %d)", #portalList))
	end
end

local function removePortal(part)
	if not portalParts[part] then return end
	portalParts[part] = nil
	for i = #portalList, 1, -1 do
		if portalList[i] == part then
			table.remove(portalList, i)
			break
		end
	end
	if DEBUG_PORTAL_FX then
		print(string.format("[BB-PORTAL] -portal (now %d)", #portalList))
	end
end

-- A NetherPortal is a single Part carrying IsPortal. But if a future portal is
-- Model-based, the attribute may sit on the model; in that case track its parts.
local function tryAdd(child)
	if isPortalPart(child) then
		addPortal(child)
	elseif child:IsA("Model") and child:GetAttribute("IsPortal") then
		for _, d in ipairs(child:GetDescendants()) do
			if d:IsA("BasePart") then addPortal(d) end
		end
	end
end

local function watchFolder(folder)
	if not folder then return end
	for _, child in ipairs(folder:GetChildren()) do
		tryAdd(child)
	end
	folder.ChildAdded:Connect(tryAdd)
	folder.ChildRemoved:Connect(function(child)
		if portalParts[child] then
			removePortal(child)
		elseif child:IsA("Model") then
			for _, d in ipairs(child:GetDescendants()) do
				if portalParts[d] then removePortal(d) end
			end
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

	-- New build areas appearing later.
	Workspace.ChildAdded:Connect(function(child)
		if child.Name:match("^" .. GridConfig.BUILD_AREA_PREFIX .. "%d+$")
			or child.Name:match("^" .. NetherConfig.NETHER_PLOT_PREFIX .. "%d+$") then
			watchBuildArea(child)
		end
	end)

	-- NetherPlot1..9 (the nether dimension baseplates). Their Blocks folders hold
	-- the return portals built by NetherTravelManager; without watching them the
	-- vision effect (and the dwell trigger that reads IsInside) never fire in the
	-- nether, so return travel + tint would silently break.
	for i = 1, GridConfig.TOTAL_PLOTS do
		local netherPlot = Workspace:FindFirstChild(NetherConfig.NETHER_PLOT_PREFIX .. i)
		if netherPlot then
			watchBuildArea(netherPlot)
		end
	end

	-- MegaPlot (lives under MegaPlotRoom or directly in workspace depending on mode).
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
local insidePortal = false
local timeSinceProbe = 0

-- The colour of the portal currently being stood in. `targetTint` is set each
-- probe tick from the part's PortalTint attribute; `currentTint` eases toward it
-- so moving between differently-coloured portals cross-fades rather than snaps.
local targetTint = DEFAULT_TINT
local currentTint = DEFAULT_TINT

-- Separate slow-ramping level for the full-screen swirl overlay. It chases the
-- main `intensity` but at SWIRL_RAMP_SPEED, so the swirl creeps in/out more
-- slowly than the tint and wobble.
local swirlLevel = 0

local function reducedEffects(): boolean
	local settings = _G.BuildBloxSettings
	if settings and settings.ReducedEffects ~= nil then
		return settings.ReducedEffects == true
	end
	return false
end

-- ============================================
-- INSIDE CHECK (cell-based, geometry-independent)
-- ============================================

-- True if `pos` lies within the portal cell of `part`. Rotation-proof: instead
-- of guessing the thin axis from local-space part.Size (which is WRONG for a
-- Z-aligned frame -- the part is rotated 90 deg about Y at placement, but
-- part.Size stays (3,3,0.4) in local space), we project the player's offset
-- from the portal centre onto the part's actual WORLD axes:
--   LookVector  = face normal  -> the THIN axis (roomy tolerance)
--   RightVector = in-plane horizontal -> WIDE tolerance
--   UpVector    = in-plane vertical   -> VERTICAL tolerance
-- The centre comes from the BlockPos attributes (exact grid centre) when set,
-- else the part's world position.
local function posInsidePortal(pos: Vector3, part: BasePart): boolean
	local cx = part:GetAttribute("BlockPosX") or part.Position.X
	local cy = part:GetAttribute("BlockPosY") or part.Position.Y
	local cz = part:GetAttribute("BlockPosZ") or part.Position.Z
	local centre = Vector3.new(cx, cy, cz)

	local cf = part.CFrame
	local offset = pos - centre

	-- Signed distances along the part's own axes (abs for tolerance compare).
	local alongNormal = math.abs(offset:Dot(cf.LookVector))   -- thin axis
	local alongRight  = math.abs(offset:Dot(cf.RightVector))  -- in-plane horizontal
	local alongUp     = math.abs(offset:Dot(cf.UpVector))     -- in-plane vertical

	return alongNormal <= THIN_TOLERANCE
		and alongRight <= WIDE_TOLERANCE
		and alongUp <= VERTICAL_TOLERANCE
end

-- Debug-only: distances from `pos` to `part`'s cell along the part's own axes,
-- plus the straight-line distance (for picking the closest part to report).
local function portalAxisDistances(pos: Vector3, part: BasePart)
	local cx = part:GetAttribute("BlockPosX") or part.Position.X
	local cy = part:GetAttribute("BlockPosY") or part.Position.Y
	local cz = part:GetAttribute("BlockPosZ") or part.Position.Z
	local offset = pos - Vector3.new(cx, cy, cz)
	local cf = part.CFrame
	return math.abs(offset:Dot(cf.LookVector)),
		math.abs(offset:Dot(cf.RightVector)),
		math.abs(offset:Dot(cf.UpVector)),
		offset.Magnitude
end

-- Read a portal part's tint (set server-side from the frame material). Falls
-- back to DEFAULT_TINT if the attribute is missing (old saves / unset).
local function tintOfPart(part: BasePart): Color3
	local t = part:GetAttribute("PortalTint")
	if typeof(t) == "Color3" then return t end
	return DEFAULT_TINT
end

-- Returns (insideBool, partOrNil). The part is the one the player is standing
-- in, so the caller can read its colour.
local function probeInsidePortal(): (boolean, BasePart?)
	if #portalList == 0 then return false, nil end
	local character = player.Character
	if not character then return false, nil end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return false, nil end
	local pos = root.Position

	for i = #portalList, 1, -1 do
		local part = portalList[i]
		if not part or not part.Parent then
			removePortal(part)
		elseif posInsidePortal(pos, part) then
			return true, part
		end
	end
	return false, nil
end

-- ============================================
-- APPLY intensity -> effects
-- ============================================

local function applyIntensity(t: number)
	-- Full shutdown only when BOTH the fast intensity AND the slow swirl are done.
	-- Otherwise the swirl could still be fading out after the tint/wobble cleared.
	if t <= 0.001 and swirlLevel <= 0.001 then
		cc.Enabled = false
		dof.Enabled = false
		blur.Enabled = false
		blur.Size = 0
		swirl.ImageTransparency = 1
		gui.Enabled = false
		return
	end

	gui.Enabled = true

	-- Tint/wobble-driven effects (ColorCorrection, DOF, blur, vignette) ride the
	-- fast `t`. They switch fully off as soon as t clears, even while the slower
	-- swirl below is still fading out.
	if t <= 0.001 then
		cc.Enabled = false
		dof.Enabled = false
		blur.Enabled = false
		blur.Size = 0
		vignette.ImageTransparency = 1
	else
		cc.Enabled = true

		local blend = t * MAX_TINT_BLEND
		cc.TintColor = Color3.new(1, 1, 1):Lerp(currentTint, blend)
		cc.Saturation = t * MAX_SATURATION
		cc.Contrast = t * MAX_CONTRAST
		cc.Brightness = t * MAX_BRIGHTNESS

		if reducedEffects() then
			dof.Enabled = false
			blur.Enabled = false
			blur.Size = 0
		else
			dof.Enabled = true
			dof.NearIntensity = t * MAX_DOF_INTENSITY
			blur.Enabled = true
			blur.Size = t * MAX_BLUR_SIZE
		end

		vignette.ImageColor3 = currentTint
		vignette.ImageTransparency = 1 - (t * MAX_VIGNETTE_ALPHA)
	end

	-- Full-screen swirl: opacity rides its own slow-ramped swirlLevel (not the
	-- fast tint/wobble intensity) up to MAX_SWIRL_ALPHA, tinted to match the
	-- dimension. Honours ReducedEffects (it's a heavy full-screen image).
	swirl.ImageColor3 = currentTint
	if reducedEffects() then
		swirl.ImageTransparency = 1
	else
		swirl.ImageTransparency = 1 - (swirlLevel * MAX_SWIRL_ALPHA)
	end
end

-- ============================================
-- MAIN LOOP
-- ============================================

RunService.RenderStepped:Connect(function(dt)
	timeSinceProbe += dt
	if timeSinceProbe >= PROBE_INTERVAL then
		timeSinceProbe = 0
		local wasInside = insidePortal
		local insidePart
		insidePortal, insidePart = probeInsidePortal()
		-- When inside, target the current portal's colour. When outside, keep the
		-- last colour as the target so the fade-OUT stays the same hue it faded in
		-- with (rather than snapping back to the default purple mid-fade).
		if insidePart then
			targetTint = tintOfPart(insidePart)
		end
		if DEBUG_PORTAL_FX and insidePortal ~= wasInside then
			print("[BB-PORTAL] vision " .. (insidePortal and "ENTER" or "EXIT"))
		end

		-- Throttled diagnostic: once per probe tick, report ONLY the closest
		-- portal part's axis distances, and only when you're actually near a
		-- portal (within ~10 studs). Keeps the log readable instead of spamming
		-- one line per part at 20 Hz.
		if DEBUG_PORTAL_FX and #portalList > 0 then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				local pos = root.Position
				local bestPart, bestDist = nil, math.huge
				local bn, br, bu
				for _, part in ipairs(portalList) do
					if part and part.Parent then
						local n, r, u, mag = portalAxisDistances(pos, part)
						if mag < bestDist then
							bestDist, bestPart = mag, part
							bn, br, bu = n, r, u
						end
					end
				end
				if bestPart and bestDist <= 10 then
					print(string.format("[BB-PORTAL] closest: normal=%.2f/%.2f right=%.2f/%.2f up=%.2f/%.2f  -> %s",
						bn, THIN_TOLERANCE, br, WIDE_TOLERANCE, bu, VERTICAL_TOLERANCE,
						insidePortal and "INSIDE" or "outside"))
				end
			end
		end
	end

	local target = insidePortal and 1 or 0
	if intensity < target then
		intensity = math.min(target, intensity + FADE_IN_SPEED * dt)
	elseif intensity > target then
		intensity = math.max(target, intensity - FADE_OUT_SPEED * dt)
	end

	-- Ease the screen colour toward the active portal's colour so crossing from
	-- one dimension's portal to another cross-fades smoothly. Exponential easing
	-- = framerate-independent.
	if currentTint ~= targetTint then
		local a = 1 - math.exp(-TINT_LERP_SPEED * dt)
		currentTint = currentTint:Lerp(targetTint, a)
	end

	-- Swirl overlay chases `intensity` at its own (slower) linear rate, so it
	-- creeps in and out independently of the snappy tint/wobble fade.
	if swirlLevel < target then
		swirlLevel = math.min(target, swirlLevel + SWIRL_RAMP_SPEED * dt)
	elseif swirlLevel > target then
		swirlLevel = math.max(target, swirlLevel - SWIRL_RAMP_SPEED * dt)
	end

	applyIntensity(intensity)
end)

player.CharacterAdded:Connect(function()
	insidePortal = false
	intensity = 0
	swirlLevel = 0
	applyIntensity(0)
end)

-- ============================================
-- EXPORT
-- ============================================
-- CameraController reads this each frame to drive the portal camera wobble.
-- The sway MUST be applied inside CameraController (it owns camera.CFrame),
-- not here -- two RenderStepped handlers both writing camera.CFrame would race
-- with no guaranteed ordering. We just surface the 0..1 intensity; the camera
-- owns the consequence. (Same client-predicts / single-owner pattern as the
-- MouseBehavior handling.)
_G.PortalVisionEffect = {
	GetIntensity = function()
		return intensity
	end,
	IsInside = function()
		return insidePortal
	end,
}

-- Delay a touch so build areas / loaded saves are present, then start watching.
task.delay(2, function()
	setupWatchers()
	if DEBUG_PORTAL_FX then
		print(string.format("[BB-PORTAL] PortalVisionEffect initialized (%d portal parts tracked)", #portalList))
	end
end)
