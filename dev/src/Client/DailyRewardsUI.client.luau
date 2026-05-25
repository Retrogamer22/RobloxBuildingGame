--[[
	DailyRewardsUI.client.luau
	Daily rewards modal — full-screen overlay with blur on launch when unclaimed
	Single row of 7 day slots with chest ViewportFrames
	Chest shakes and opens on claim
	Only shows when reward is available; hidden if already claimed today
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local CoinConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("CoinConfig"))
local LootConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DailyRewardLootConfig"))
local RewardSetPicker = require(ReplicatedStorage:WaitForChild("RewardSetPicker"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local GetCoinData = Remotes:WaitForChild("GetCoinData", 10)
local ClaimDailyReward = Remotes:WaitForChild("ClaimDailyReward", 10)
local DailyRewardResult = Remotes:WaitForChild("DailyRewardResult", 10)

-- ============================================
-- CONFIG
-- ============================================
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local FONT = Enum.Font.Arcade
local FONT_BODY = Enum.Font.GothamBold
local BEVEL = 2

local C = {
	panelBg = Color3.fromRGB(24, 20, 20),
	headerBg = Color3.fromRGB(50, 42, 42),
	bevelHL = Color3.fromRGB(60, 54, 54),
	bevelSH = Color3.fromRGB(14, 12, 12),

	slotClaimed = Color3.fromRGB(35, 60, 35),
	slotClaimedBevelHL = Color3.fromRGB(50, 80, 50),
	slotClaimedBevelSH = Color3.fromRGB(20, 40, 20),

	slotCurrent = Color3.fromRGB(45, 55, 75),
	slotCurrentBevelHL = Color3.fromRGB(65, 78, 100),
	slotCurrentBevelSH = Color3.fromRGB(28, 35, 50),

	slotLocked = Color3.fromRGB(28, 25, 25),
	slotLockedBevelHL = Color3.fromRGB(42, 38, 38),
	slotLockedBevelSH = Color3.fromRGB(16, 14, 14),

	gold = Color3.fromRGB(255, 200, 50),
	goldDim = Color3.fromRGB(180, 140, 30),

	green = Color3.fromRGB(76, 175, 80),
	greenHover = Color3.fromRGB(100, 200, 104),
	greenPress = Color3.fromRGB(56, 140, 60),
	greenBevelHL = Color3.fromRGB(130, 220, 130),
	greenBevelSH = Color3.fromRGB(40, 100, 40),

	disabledBtn = Color3.fromRGB(55, 50, 50),
	disabledBevelHL = Color3.fromRGB(75, 68, 68),
	disabledBevelSH = Color3.fromRGB(30, 26, 26),

	text = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(140, 140, 140),
	textMuted = Color3.fromRGB(90, 85, 85),

	overlayColor = Color3.fromRGB(0, 0, 0),
}

-- Mobile: use full screen width on phones/tablets so the modal really fills the space
-- Desktop: fixed 780px
-- NOTE: ViewportSize may not be initialized at module load. PANEL_WIDTH here is a
-- FALLBACK for initial slot sizing. The Panel itself uses scale on mobile so it
-- always fills the actual ScreenGui, and relayoutDays() reflows slots when the
-- panel's AbsoluteSize changes.
local PANEL_WIDTH
if IsMobile then
	local cam = workspace.CurrentCamera
	local screenW = cam and cam.ViewportSize.X or 600
	print("[BB-DR] Initial mobile ViewportSize.X =", screenW, "(if this is small, panel will auto-grow once viewport is ready)")
	PANEL_WIDTH = math.clamp(math.floor(screenW * 1.0), 300, 2000)
else
	PANEL_WIDTH = 780
end
local OVERLAY_TRANSPARENCY = 0.4
local BLUR_SIZE = 20

local GRID_PAD = IsMobile and 8 or 6
local COLS = 7
local innerW = PANEL_WIDTH - 12
local SLOT_W = math.floor((innerW - GRID_PAD * (COLS + 1)) / COLS)
-- Keep slots in a sensible aspect ratio. If the screen reports a narrow viewport,
-- slots become tall+narrow vertical strips and the chests look squished. Cap the
-- height relative to width so they stay roughly square (or slightly taller).
local SLOT_H
if IsMobile then
	SLOT_H = math.clamp(math.floor(SLOT_W * 1.15), 80, 140)
else
	SLOT_H = 110
end
local CLAIM_H = IsMobile and 52 or 44
local HEADER_H = IsMobile and 50 or 42
local GRID_Y = HEADER_H + 8

-- Header layout: badges go on the right of the title. The dev-only close button
-- (Studio only) sits at the far right, so badges shift left to make room for it.
local HEADER_HAS_CLOSE = RunService:IsStudio()
local CLOSE_BTN_AREA   = HEADER_HAS_CLOSE and 34 or 0  -- close button width + gap
local BADGE_W_WEEK     = IsMobile and 85 or 70
local BADGE_W_STREAK   = IsMobile and 72 or 60
local BADGE_H_HDR      = IsMobile and 28 or 22
local BADGE_FONT_SIZE  = IsMobile and 14 or 11
local BADGE_GAP        = 4
local BADGE_RIGHT_PAD  = 6 + CLOSE_BTN_AREA  -- 6px margin from right edge, plus close button reserve
-- StreakBadge is the leftmost right-side element; title must not overlap it.
local STREAK_LEFT_FROM_RIGHT = BADGE_RIGHT_PAD + BADGE_W_WEEK + BADGE_GAP + BADGE_W_STREAK
local TITLE_RIGHT_MARGIN = STREAK_LEFT_FROM_RIGHT + 8  -- 8px gap between title and streak badge

-- Vertical gap between the days row and the claim button. 4 looked cramped on
-- mobile (chests appeared to touch the claim button), 12 still slightly tight,
-- 20 gives the claim button proper breathing room below the slots.
local CLAIM_GAP = 20

local PANEL_HEIGHT = 12 + GRID_Y + SLOT_H + GRID_PAD * 2 + CLAIM_GAP + CLAIM_H + 18

local IsClaiming = false
local DailyStatus = nil
local DayFrames = {}

-- Forward declarations for functions used in UI callbacks
local hideModal
local showModal
local restorePanelVisuals

-- ============================================
-- BEVEL HELPER
-- ============================================
local function addBevel(parent, hlColor, shColor, bevelSize)
	local hl = hlColor or C.bevelHL
	local sh = shColor or C.bevelSH
	local b = bevelSize or BEVEL
	local z = parent.ZIndex + 1
	local top = Instance.new("Frame"); top.Name = "BT"; top.Size = UDim2.new(1, 0, 0, b)
	top.BackgroundColor3 = hl; top.BorderSizePixel = 0; top.ZIndex = z; top.Parent = parent
	local left = Instance.new("Frame"); left.Name = "BL"; left.Size = UDim2.new(0, b, 1, 0)
	left.BackgroundColor3 = hl; left.BorderSizePixel = 0; left.ZIndex = z; left.Parent = parent
	local bottom = Instance.new("Frame"); bottom.Name = "BB"; bottom.Size = UDim2.new(1, 0, 0, b)
	bottom.Position = UDim2.new(0, 0, 1, -b)
	bottom.BackgroundColor3 = sh; bottom.BorderSizePixel = 0; bottom.ZIndex = z; bottom.Parent = parent
	local right = Instance.new("Frame"); right.Name = "BR"; right.Size = UDim2.new(0, b, 1, 0)
	right.Position = UDim2.new(1, -b, 0, 0)
	right.BackgroundColor3 = sh; right.BorderSizePixel = 0; right.ZIndex = z; right.Parent = parent
	return {top = top, left = left, bottom = bottom, right = right}
end

local function setBevel(bv, hl, sh)
	bv.top.BackgroundColor3 = hl; bv.left.BackgroundColor3 = hl
	bv.bottom.BackgroundColor3 = sh; bv.right.BackgroundColor3 = sh
end

-- ============================================
-- CHEST VIEWPORT HELPERS
-- ============================================

-- Compute hinge CFrame for chest lid opening
-- The hinge is at the back-top edge of the Bottom model (opposite from latch).
-- IMPORTANT: We return the hinge in the chest's LOCAL space, then convert to world
-- at animation time. This way the hinge axis is the chest's local X (the edge line)
-- and works correctly no matter how the chest model is rotated in the viewport.
local function computeHinge(chestModel)
	local bottom = chestModel:FindFirstChild("Bottom")
	if not bottom then return CFrame.new() end

	local modelCF = chestModel:GetPivot()
	local modelInv = modelCF:Inverse()

	-- Find top surface Y and Z extents of bottom parts, in the chest's LOCAL frame
	local topY = -math.huge
	local minZ, maxZ = math.huge, -math.huge
	local centerX = 0
	local count = 0

	for _, part in bottom:GetDescendants() do
		if part:IsA("BasePart") then
			local localPos = modelInv * part.Position
			local hs = part.Size / 2
			topY = math.max(topY, localPos.Y + hs.Y)
			minZ = math.min(minZ, localPos.Z - hs.Z)
			maxZ = math.max(maxZ, localPos.Z + hs.Z)
			centerX = centerX + localPos.X
			count = count + 1
		end
	end

	if count == 0 then return CFrame.new() end
	centerX = centerX / count

	-- Determine which Z edge is "back" by finding the latch (front) — also in local space
	local top = chestModel:FindFirstChild("Top")
	local latchZ = nil
	if top then
		local latch = top:FindFirstChild("Latch")
		if latch then
			if latch:IsA("BasePart") then
				latchZ = (modelInv * latch.Position).Z
			else
				for _, p in latch:GetDescendants() do
					if p:IsA("BasePart") then latchZ = (modelInv * p.Position).Z; break end
				end
			end
		end
	end

	-- Back edge is farthest from latch
	local backZ
	if latchZ then
		backZ = (math.abs(latchZ - minZ) > math.abs(latchZ - maxZ)) and minZ or maxZ
	else
		backZ = minZ -- default
	end

	-- Return local-space hinge; callers convert to world via modelCF * localHingeCF
	return CFrame.new(centerX, topY, backZ)
end

-- Store original CFrames of all Top parts, in the chest's LOCAL frame.
-- Storing locally (instead of world CFrames) means the lid rotation is applied
-- relative to the chest's orientation, not world axes.
local function getTopPartCFs(chestModel)
	local top = chestModel:FindFirstChild("Top")
	if not top then return {} end
	local modelInv = chestModel:GetPivot():Inverse()
	local cfs = {}
	for _, part in top:GetDescendants() do
		if part:IsA("BasePart") then
			-- Store both the local CFrame (for animation) and a ref to the chest model
			-- so we can rebuild world CFrames each frame.
			cfs[part] = modelInv * part.CFrame
		end
	end
	-- Stash the chest model alongside so setLidAngle can get its current pivot.
	cfs._chestModel = chestModel
	return cfs
end

-- Set the lid to a specific open angle.
-- Rotation happens around the chest's LOCAL X axis (the hinge line) regardless
-- of how the chest is oriented in the world.
local function setLidAngle(topCFs, hingeCF, angle)
	local chestModel = topCFs._chestModel
	if not chestModel or not chestModel.Parent then return end
	local modelCF = chestModel:GetPivot()
	local worldHinge = modelCF * hingeCF
	for part, localOrigCF in pairs(topCFs) do
		if typeof(localOrigCF) == "CFrame" then
			-- localOrigCF is the part's pose relative to the chest model.
			-- Convert the stored local CF into a local offset from the local hinge,
			-- rotate by angle around the hinge's X axis, then transform back to world.
			local localOffset = hingeCF:Inverse() * localOrigCF
			part.CFrame = worldHinge * CFrame.Angles(angle, 0, 0) * localOffset
		end
	end
end

-- Chest template (loaded after game finishes loading)
local ChestTemplate = nil

-- Create a ViewportFrame with a cloned chest inside
local function createChestViewport(parent, zIndex)
	if not ChestTemplate then return nil, nil end

	local viewportSize = IsMobile and UDim2.new(1, -8, 1, -26) or UDim2.new(1, -8, 1, -40)

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "ChestViewport"
	viewport.Size = viewportSize
	viewport.Position = UDim2.new(0.5, 0, 0.5, 2)
	viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	viewport.BackgroundTransparency = 1
	viewport.ZIndex = zIndex
	viewport.Ambient = Color3.fromRGB(140, 140, 140)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-1, -1.5, -0.5).Unit
	viewport.Parent = parent

	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "World"
	worldModel.Parent = viewport

	local camera = Instance.new("Camera")
	camera.FieldOfView = 39
	camera.CFrame = CFrame.new(Vector3.new(5.5, 4.5, 5.5), Vector3.new(0, 0.5, 0))
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	-- Clone chest and apply oak wood colors (same as inventory setupViewportModel)
	local chest = ChestTemplate:Clone()

	local oakColor = Color3.fromRGB(186, 145, 90)
	local oakMaterial = Enum.Material.WoodPlanks
	local oakVariant = "PixelWoodPlanksSeperated"
	local BlocksFolder = ReplicatedStorage:FindFirstChild("Blocks")
	if BlocksFolder then
		local oakPlanks = BlocksFolder:FindFirstChild("OakPlanks")
		if oakPlanks then
			local pp = oakPlanks:IsA("BasePart") and oakPlanks or oakPlanks:FindFirstChildWhichIsA("BasePart")
			if pp then
				oakColor = pp.Color
				oakMaterial = pp.Material
				oakVariant = pp.MaterialVariant or oakVariant
			end
		end
	end

	local h, s, v = Color3.toHSV(oakColor)
	local trimColor = Color3.fromHSV(h, math.min(s * 0.75, 1), v * 0.38)

	for _, part in chest:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			local group = nil
			local ancestor = part.Parent
			while ancestor and ancestor ~= chest do
				local n = ancestor.Name
				if n == "Edge" or n == "Latch" or n == "Darkness" then group = n; break end
				ancestor = ancestor.Parent
			end
			if not group then
				local n = part.Name
				if n == "Edge" or n == "Latch" or n == "Darkness" then group = n end
			end
			if group ~= "Latch" and group ~= "Darkness" then
				if group == "Edge" then
					part.Color = trimColor
				else
					part.Color = oakColor
				end
				part.Material = oakMaterial
				if oakVariant ~= "" then part.MaterialVariant = oakVariant end
			end
		end
	end

	-- PivotTo origin (slight upward offset only), rotated 180deg so latch faces camera.
	-- Less downward offset than the original -1.0 since there's no reward label below
	-- the chest anymore, so the chest can sit closer to slot center without clipping.
	chest:PivotTo(CFrame.new(0, -0.3, 0) * CFrame.Angles(0, math.rad(180), 0))
	chest.Parent = worldModel

	-- Compute hinge and store original top CFs for animation
	local hingeCF = computeHinge(chest)
	local topCFs = getTopPartCFs(chest)

	return viewport, chest, hingeCF, topCFs
end

-- ============================================
-- CHEST ANIMATIONS
-- ============================================

-- Shake the chest model (wobble on Z rotation)
local function animateShake(chestModel, duration, buildUp, callback)
	if not chestModel then if callback then callback() end return end

	local allParts = {}
	local originalCFs = {}
	for _, part in chestModel:GetDescendants() do
		if part:IsA("BasePart") then
			table.insert(allParts, part)
			originalCFs[part] = part.CFrame
		end
	end

	local cOk, modelCF = pcall(function() return chestModel:GetBoundingBox() end)
	local pivot = cOk and modelCF.Position or Vector3.new(0, 0.2, 0)
	local pivotCF = CFrame.new(pivot)

	local elapsed = 0

	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed = elapsed + dt
		if elapsed >= duration then
			for part, origCF in pairs(originalCFs) do
				part.CFrame = origCF
			end
			conn:Disconnect()
			if callback then callback() end
			return
		end

		local t = elapsed / duration
		-- Build-up: intensity increases over time
		local intensity
		if buildUp then
			intensity = t * t -- Quadratic ramp up
		else
			intensity = math.exp(-3.0 * t) -- Decay
		end

		-- Frequency increases as intensity builds
		local freq = buildUp and (10 + t * 20) or 18
		local maxAngle = buildUp and math.rad(6 + t * 12) or math.rad(12)
		local angle = math.sin(elapsed * freq * math.pi * 2) * maxAngle * intensity

		for part, origCF in pairs(originalCFs) do
			local offset = pivotCF:Inverse() * origCF
			part.CFrame = pivotCF * CFrame.Angles(0, 0, angle) * offset
		end
	end)
end

-- Animate the lid opening from closed to a target angle
local function animateLidOpen(topCFs, hingeCF, targetAngle, duration, callback)
	if not hingeCF or not topCFs or not next(topCFs) then
		if callback then callback() end
		return
	end

	local elapsed = 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed = elapsed + dt
		local t = math.min(elapsed / duration, 1)
		-- Ease out back (slight overshoot for dramatic pop)
		local c1 = 1.4
		local eased = 1 + (c1 + 1) * ((t - 1) ^ 3) + c1 * ((t - 1) ^ 2)
		local angle = targetAngle * eased

		setLidAngle(topCFs, hingeCF, angle)

		if t >= 1 then
			conn:Disconnect()
			if callback then callback() end
		end
	end)
end

-- ============================================
-- SPOTLIGHT SYSTEM (zoom chest to center screen)
-- ============================================
local SpotlightViewport = nil
local SpotlightWorldModel = nil
local SpotlightCamera = nil
local SpotlightBg = nil

local SpotlightGui = nil

local function createSpotlight()
	-- Separate ScreenGui with higher DisplayOrder so spotlight is always on top
	SpotlightGui = Instance.new("ScreenGui")
	SpotlightGui.Name = "DailyRewardsSpotlight"
	SpotlightGui.ResetOnSpawn = false
	SpotlightGui.DisplayOrder = 200
	SpotlightGui.IgnoreGuiInset = true
	SpotlightGui.Enabled = false
	SpotlightGui.Parent = PlayerGui

	-- Dark background behind the spotlight chest
	SpotlightBg = Instance.new("Frame")
	SpotlightBg.Name = "SpotlightBg"
	SpotlightBg.Size = UDim2.new(1, 0, 1, 0)
	SpotlightBg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	SpotlightBg.BackgroundTransparency = 1
	SpotlightBg.BorderSizePixel = 0
	SpotlightBg.Active = true -- Block touch input during animation
	SpotlightBg.Parent = SpotlightGui

	SpotlightViewport = Instance.new("ViewportFrame")
	SpotlightViewport.Name = "SpotlightChest"
	SpotlightViewport.BackgroundTransparency = 1
	SpotlightViewport.Ambient = Color3.fromRGB(160, 155, 145)
	SpotlightViewport.LightColor = Color3.fromRGB(255, 255, 255)
	SpotlightViewport.LightDirection = Vector3.new(-1, -1.5, -0.5).Unit
	SpotlightViewport.Parent = SpotlightGui

	SpotlightWorldModel = Instance.new("WorldModel")
	SpotlightWorldModel.Name = "World"
	SpotlightWorldModel.Parent = SpotlightViewport

	SpotlightCamera = Instance.new("Camera")
	SpotlightCamera.FieldOfView = 30
	SpotlightCamera.CFrame = CFrame.new(Vector3.new(16, 10, 16), Vector3.new(0, 1, 0))
	SpotlightCamera.Parent = SpotlightViewport
	SpotlightViewport.CurrentCamera = SpotlightCamera
end

-- Coin burst animation — coins pop out of the chest
local CoinTemplate = nil

local function spawnCoinBurst(worldModel, chestModel, numCoins)
	-- Lazy-load the coin template
	if not CoinTemplate then
		local gameAssets = ReplicatedStorage:FindFirstChild("GameAssets")
		if gameAssets then
			CoinTemplate = gameAssets:FindFirstChild("bloxCoin")
		end
		if not CoinTemplate then
			warn("[BB-DR] bloxCoin not found in GameAssets")
			return
		end
	end

	-- Find the launch point (at the chest opening, top of the body)
	local launchY = 1.5
	local bottom = chestModel:FindFirstChild("Bottom")
	if bottom then
		local ok, cf, size = pcall(function() return bottom:GetBoundingBox() end)
		if ok then
			launchY = cf.Position.Y + size.Y / 2 + 0.3
		end
	end
	local launchPos = Vector3.new(0, launchY, 0)

	local coins = {}
	local rng = Random.new()
	local count = numCoins or 8

	for i = 1, count do
		local coin = CoinTemplate:Clone()

		-- Handle both Model and BasePart coins
		if coin:IsA("Model") then
			for _, part in coin:GetDescendants() do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = false
					part.Transparency = 1 -- Start invisible, pop in
				end
			end
			coin:PivotTo(CFrame.new(launchPos))
		elseif coin:IsA("BasePart") then
			coin.Anchored = true
			coin.CanCollide = false
			coin.Transparency = 1
			coin.CFrame = CFrame.new(launchPos)
		end

		coin.Parent = worldModel

		-- Spread coins in a ring pattern for a dramatic fountain
		local angle = (i / count) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local hSpeed = rng:NextNumber(2, 5)
		local vx = math.cos(angle) * hSpeed
		local vy = rng:NextNumber(6, 12)
		local vz = math.sin(angle) * hSpeed

		-- Random spin (tumble on multiple axes for drama)
		local spinX = rng:NextNumber(6, 14) * (rng:NextInteger(0, 1) == 0 and 1 or -1)
		local spinY = rng:NextNumber(4, 10) * (rng:NextInteger(0, 1) == 0 and 1 or -1)

		-- Stagger spawn in waves
		local delay = rng:NextNumber(0, 0.2)

		table.insert(coins, {
			model = coin,
			velocity = Vector3.new(vx, vy, vz),
			spinX = spinX,
			spinY = spinY,
			angleX = rng:NextNumber(0, math.pi * 2),
			angleY = rng:NextNumber(0, math.pi * 2),
			elapsed = -delay,
			pos = launchPos,
			isModel = coin:IsA("Model"),
		})
	end

	local GRAVITY = -14
	local LIFETIME = 1.6
	local FADE_START = 0.7
	local POP_IN = 0.05 -- coins pop visible this fast

	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		local allDone = true

		for _, c in coins do
			c.elapsed = c.elapsed + dt

			if c.elapsed < 0 then
				allDone = false
				continue
			end

			if c.elapsed >= LIFETIME then
				if c.model.Parent then c.model:Destroy() end
				continue
			end

			allDone = false

			-- Apply gravity
			c.velocity = c.velocity + Vector3.new(0, GRAVITY * dt, 0)
			c.pos = c.pos + c.velocity * dt
			c.angleX = c.angleX + c.spinX * dt
			c.angleY = c.angleY + c.spinY * dt

			local t = c.elapsed / LIFETIME

			-- Pop in instantly, fade out at end
			local alpha
			if t < POP_IN then
				alpha = t / POP_IN
			elseif t > FADE_START then
				alpha = 1 - (t - FADE_START) / (1 - FADE_START)
			else
				alpha = 1
			end

			-- Tumble on X and Y axes
			local cf = CFrame.new(c.pos) * CFrame.Angles(c.angleX, c.angleY, 0)

			if c.isModel then
				c.model:PivotTo(cf)
				for _, part in c.model:GetDescendants() do
					if part:IsA("BasePart") then
						part.Transparency = 1 - alpha
					end
				end
			else
				c.model.CFrame = cf
				c.model.Transparency = 1 - alpha
			end
		end

		if allDone then
			conn:Disconnect()
		end
	end)
end

-- Block burst — the reward set's model pops out of the chest and floats up
-- rewardSet shape: { name, model, grants, rarity } from RewardSetPicker
local function spawnBlockBurst(worldModel, chestModel, rewardSet)
	if not rewardSet or not rewardSet.model then
		warn("[BB-DR] spawnBlockBurst called with no model; nothing to render")
		return
	end

	-- Clone the model from ReplicatedStorage.RewardBlocks
	local block = rewardSet.model:Clone()
	block.Name = "RewardBlock"

	-- Find launch point (same as coin burst)
	local launchY = 1.5
	local bottom = chestModel:FindFirstChild("Bottom")
	if bottom then
		local ok, cf, size = pcall(function() return bottom:GetBoundingBox() end)
		if ok then
			launchY = cf.Position.Y + size.Y / 2 + 0.3
		end
	end

	local startPos = Vector3.new(0, launchY, 0)

	-- Cache original transparencies so we can fade in/out without losing the model's look
	local originalTransparency = {}
	for _, desc in ipairs(block:GetDescendants()) do
		if desc:IsA("BasePart") then
			originalTransparency[desc] = desc.Transparency
			desc.Transparency = 1 -- start invisible
			desc.CanCollide = false
			desc.Anchored = true
		elseif desc:IsA("Decal") or desc:IsA("Texture") then
			originalTransparency[desc] = desc.Transparency
			desc.Transparency = 1
		end
	end

	-- Parent and position
	block.Parent = worldModel
	block:PivotTo(CFrame.new(startPos))

	-- Also spawn a couple coins alongside (fewer than a coin-only day)
	spawnCoinBurst(worldModel, chestModel, 2)

	-- Animate: pop in, float up slowly, spin, fade out
	local elapsed = 0
	local FLOAT_SPEED = 2.5
	local SPIN_SPEED = 3
	local LIFETIME = 2.0

	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed = elapsed + dt
		if elapsed >= LIFETIME then
			if block.Parent then block:Destroy() end
			conn:Disconnect()
			return
		end

		local t = elapsed / LIFETIME

		-- Float upward with deceleration
		local pos = startPos + Vector3.new(0, FLOAT_SPEED * elapsed * (1 - t * 0.3), 0)

		-- Spin
		local angle = elapsed * SPIN_SPEED
		local cf = CFrame.new(pos) * CFrame.Angles(0, angle, math.sin(elapsed * 2) * 0.2)
		block:PivotTo(cf)

		-- Pop in fast, hold, fade out at end. Scale to each part's original transparency
		-- so a partly-transparent material (like glass) still ends up at its intended value.
		local fadeMul -- 0 = fully visible (use original), 1 = fully invisible
		if t < 0.08 then
			fadeMul = 1 - (t / 0.08)
		elseif t > 0.75 then
			fadeMul = (t - 0.75) / 0.25
		else
			fadeMul = 0
		end
		for inst, origT in pairs(originalTransparency) do
			if inst.Parent then
				inst.Transparency = origT + (1 - origT) * fadeMul
			end
		end
	end)
end

-- Floating "+N Coins!" popup. Spawns inside the SpotlightGui (full-screen,
-- on top of the viewport) and rises from just above screen center while
-- fading out. Pairs with the coin-burst visual so the player sees both the
-- coins fly out AND the exact number they got.
local function spawnCoinAmountPopup(amount)
	if not SpotlightGui then return end

	local label = Instance.new("TextLabel")
	label.Name = "CoinAmountPopup"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Start slightly above chest center (chest sits around screen-center; we
	-- want the popup just above the lid so it doesn't overlap the chest body).
	label.Position = UDim2.new(0.5, 0, 0.42, 0)
	label.Size = UDim2.new(0, 600, 0, 120)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Arcade
	label.Text = "+" .. tostring(amount) .. " Coins!"
	label.TextColor3 = Color3.fromRGB(255, 220, 90) -- gold, matches BloxCoin theme
	label.TextStrokeColor3 = Color3.fromRGB(80, 50, 0) -- dark gold outline
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.TextTransparency = 1 -- fade in below
	label.ZIndex = 50
	label.Parent = SpotlightGui

	-- Brief pop-in: scale from 80% to 100% with Back easing while fading in.
	local scale = Instance.new("UIScale")
	scale.Scale = 0.8
	scale.Parent = label

	local popIn = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(scale, popIn, { Scale = 1.0 }):Play()
	TweenService:Create(label, TweenInfo.new(0.18), {
		TextTransparency = 0,
		TextStrokeTransparency = 0,
	}):Play()

	-- Float up + fade out. We hold the popup at full opacity for ~1.4s, then
	-- stretch the upward float + fade over ~1.4s on top, for a total visible
	-- lifetime around 3s. The chest-claim flow's post-burst wait is extended
	-- to match (see `task.wait(3.2)` below) so the spotlight doesn't fade out
	-- before the popup finishes.
	task.delay(1.4, function()
		if not label.Parent then return end
		local floatInfo = TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(label, floatInfo, {
			Position = UDim2.new(0.5, 0, 0.28, 0),
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
		task.delay(1.45, function()
			if label.Parent then label:Destroy() end
		end)
	end)
end

-- Full claim animation: zoom to center, suspenseful shake, dramatic open
-- coinAmount controls how many coins burst out, rewardBlock is nil for coins
local function animateChestClaim(dayData, coinAmount, rewardBlock, callback)
	if not SpotlightViewport then createSpotlight() end

	-- Clone the chest into the spotlight viewport
	local chest = dayData.chestModel
	if not chest then if callback then callback() end return end

	local clonedChest = chest:Clone()
	for _, child in SpotlightWorldModel:GetChildren() do child:Destroy() end
	clonedChest.Parent = SpotlightWorldModel

	-- Compute hinge/topCFs for the cloned chest
	local spotHinge = computeHinge(clonedChest)
	local spotTopCFs = getTopPartCFs(clonedChest)

	-- Get the slot viewport's absolute position/size for the zoom-from point
	local slotViewport = dayData.viewport
	local startPos, startSize
	if slotViewport then
		startPos = slotViewport.AbsolutePosition
		startSize = slotViewport.AbsoluteSize
	else
		startPos = Vector2.new(400, 300)
		startSize = Vector2.new(80, 80)
	end

	-- Target: full screen viewport so coins never clip
	local camera = workspace.CurrentCamera
	local targetW = camera and camera.ViewportSize.X or 1920
	local targetH = camera and camera.ViewportSize.Y or 1080

	-- Set spotlight starting position (matching the slot)
	SpotlightViewport.Position = UDim2.new(0, startPos.X, 0, startPos.Y)
	SpotlightViewport.Size = UDim2.new(0, startSize.X, 0, startSize.Y)
	SpotlightViewport.ImageTransparency = 0
	SpotlightBg.BackgroundTransparency = 1
	SpotlightGui.Enabled = true

	-- Hide the original slot viewport so it doesn't z-fight with the clone
	if slotViewport then
		slotViewport.ImageTransparency = 1
	end

	-- Phase 1: Zoom to center (0.5s)
	-- Expand to full screen, chest stays centered via camera
	TweenService:Create(SpotlightViewport, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0, 0, 0, 0),
		Size = UDim2.new(1, 0, 1, 0),
	}):Play()

	-- Darken background behind spotlight
	TweenService:Create(SpotlightBg, TweenInfo.new(0.4), {
		BackgroundTransparency = 0.6,
	}):Play()

	task.wait(0.55)

	-- Phase 2: Suspenseful shake — builds in intensity (2s)
	animateShake(clonedChest, 2.0, true, function()
		-- Phase 3: Brief dramatic pause (anticipation)
		task.wait(0.3)

		-- Phase 4: Lid pops open with overshoot (0.4s)
		animateLidOpen(spotTopCFs, spotHinge, math.rad(110), 0.4, function()
			-- Burst out coins or a reward block
			if rewardBlock then
				spawnBlockBurst(SpotlightWorldModel, clonedChest, rewardBlock)
				task.wait(2.2) -- longer hold for block reveal
			else
				local burstCount = math.clamp(math.floor((coinAmount or 50) / 20) + 2, 3, 14)
				spawnCoinBurst(SpotlightWorldModel, clonedChest, burstCount)
				-- Floating "+N Coins!" popup that rises from the chest and fades.
				-- Lives on SpotlightGui (above the viewport) so it doesn't need any
				-- 3D camera math — the chest is at screen center during the burst.
				if coinAmount and coinAmount > 0 then
					spawnCoinAmountPopup(coinAmount)
				end
				-- Hold the spotlight long enough for the coin-amount popup to play
				-- through its full lifetime (~3s: pop in → 1.4s hold → 1.4s float+fade).
				task.wait(3.2)
			end

			-- Phase 5: Fade out spotlight
			TweenService:Create(SpotlightViewport, TweenInfo.new(0.4), {
				ImageTransparency = 1,
			}):Play()
			TweenService:Create(SpotlightBg, TweenInfo.new(0.4), {
				BackgroundTransparency = 1,
			}):Play()

			task.delay(0.45, function()
				SpotlightGui.Enabled = false
				for _, child in SpotlightWorldModel:GetChildren() do child:Destroy() end
				-- Sweep any popup UI we parented to SpotlightGui (CoinAmountPopup self-cleans,
				-- but if the claim animation gets cut short for any reason we don't want a
				-- stale invisible label lingering between sessions).
				for _, child in SpotlightGui:GetChildren() do
					if child.Name == "CoinAmountPopup" then child:Destroy() end
				end
				-- Restore slot viewport visibility
				if slotViewport then
					slotViewport.ImageTransparency = 0
				end
			end)

			-- Also open the original chest in its slot
			if dayData.topCFs and dayData.hingeCF then
				setLidAngle(dayData.topCFs, dayData.hingeCF, math.rad(100))
			end

			if callback then callback() end
		end)
	end)
end

-- ============================================
-- SCREEN GUI (high display order, above everything)
-- ============================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "DailyRewardsUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 150
ScreenGui.IgnoreGuiInset = true
ScreenGui.Enabled = false
ScreenGui.Parent = PlayerGui

-- ============================================
-- BLUR EFFECT
-- ============================================
local BlurEffect = Instance.new("BlurEffect")
BlurEffect.Name = "DailyRewardsBlur"
BlurEffect.Size = 0

-- ============================================
-- FULL-SCREEN DARK OVERLAY
-- ============================================
local Overlay = Instance.new("Frame")
Overlay.Name = "Overlay"
Overlay.Size = UDim2.new(1, 0, 1, 0)
Overlay.BackgroundColor3 = C.overlayColor
Overlay.BackgroundTransparency = 1
Overlay.BorderSizePixel = 0
Overlay.ZIndex = 1
Overlay.Active = true -- Block touch input from passing through to the game
Overlay.Parent = ScreenGui

-- ============================================
-- MAIN PANEL (centered)
-- ============================================
local Panel = Instance.new("Frame")
Panel.Name = "DailyRewardsPanel"
-- On mobile, use scale-based width so the panel always fills the ScreenGui no
-- matter what ViewportSize was at module load. On desktop, fixed pixel width.
if IsMobile then
	Panel.Size = UDim2.new(1, -16, 0, PANEL_HEIGHT) -- 8px margin on each side
else
	Panel.Size = UDim2.new(0, PANEL_WIDTH, 0, PANEL_HEIGHT)
end
Panel.BackgroundColor3 = C.panelBg
Panel.BackgroundTransparency = 0
Panel.BorderSizePixel = 0
Panel.AnchorPoint = Vector2.new(0.5, 0.5)
Panel.Position = UDim2.new(0.5, 0, 0.5, 0)
Panel.ZIndex = 10
Panel.Active = true -- Block touch input on mobile
Panel.Parent = ScreenGui
addBevel(Panel, C.bevelHL, C.bevelSH)

-- Inner padding
local Inner = Instance.new("Frame")
Inner.Name = "Inner"
Inner.Size = UDim2.new(1, -12, 1, -12)
Inner.Position = UDim2.new(0, 6, 0, 6)
Inner.BackgroundTransparency = 1
Inner.ZIndex = 11
Inner:SetAttribute("KeepTransparent", true)
Inner.Parent = Panel

-- ============================================
-- HEADER
-- ============================================
local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, HEADER_H)
Header.BackgroundColor3 = C.headerBg
Header.BorderSizePixel = 0; Header.ZIndex = 11; Header.Parent = Inner
addBevel(Header, Color3.fromRGB(70, 62, 62), Color3.fromRGB(30, 24, 24))

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -TITLE_RIGHT_MARGIN, 1, 0); Title.Position = UDim2.new(0, 10, 0, 0)
Title.BackgroundTransparency = 1; Title.Text = IsMobile and "Rewards" or "Daily Rewards"
Title.TextColor3 = C.text; Title.Font = FONT
Title.TextSize = IsMobile and 22 or 18
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.TextTruncate = Enum.TextTruncate.AtEnd
Title.ZIndex = 12; Title.Parent = Header

-- Week badge (shows current week number; updated by updateDisplay)
local WeekBadgeFrame = Instance.new("Frame")
WeekBadgeFrame.Name = "WeekBadge"
WeekBadgeFrame.Size = UDim2.new(0, BADGE_W_WEEK, 0, BADGE_H_HDR)
WeekBadgeFrame.Position = UDim2.new(1, -BADGE_RIGHT_PAD, 0.5, 0)
WeekBadgeFrame.AnchorPoint = Vector2.new(1, 0.5)
WeekBadgeFrame.BackgroundColor3 = Color3.fromRGB(140, 100, 200) -- purple to distinguish from gold streak badge
WeekBadgeFrame.BorderSizePixel = 0
WeekBadgeFrame.ZIndex = 12; WeekBadgeFrame.Parent = Header
WeekBadgeFrame:SetAttribute("TargetTransparency", 0)
addBevel(WeekBadgeFrame, Color3.fromRGB(180, 140, 230), Color3.fromRGB(70, 50, 100), 1)

local WeekBadge = Instance.new("TextLabel")
WeekBadge.Size = UDim2.new(1, 0, 1, 0)
WeekBadge.BackgroundTransparency = 1
WeekBadge.Text = "Week 1"; WeekBadge.TextColor3 = Color3.fromRGB(255, 255, 255)
WeekBadge.Font = FONT; WeekBadge.TextSize = BADGE_FONT_SIZE
WeekBadge.ZIndex = 13; WeekBadge.Parent = WeekBadgeFrame

-- Streak badge (Day N within current week)
local StreakBadgeFrame = Instance.new("Frame")
StreakBadgeFrame.Name = "StreakBadge"
StreakBadgeFrame.Size = UDim2.new(0, BADGE_W_STREAK, 0, BADGE_H_HDR)
StreakBadgeFrame.Position = UDim2.new(1, -(BADGE_RIGHT_PAD + BADGE_W_WEEK + BADGE_GAP), 0.5, 0)
StreakBadgeFrame.AnchorPoint = Vector2.new(1, 0.5)
StreakBadgeFrame.BackgroundColor3 = C.gold; StreakBadgeFrame.BorderSizePixel = 0
StreakBadgeFrame.ZIndex = 12; StreakBadgeFrame.Parent = Header
StreakBadgeFrame:SetAttribute("TargetTransparency", 0)
addBevel(StreakBadgeFrame, Color3.fromRGB(255, 230, 130), Color3.fromRGB(120, 90, 10), 1)

local StreakBadge = Instance.new("TextLabel")
StreakBadge.Size = UDim2.new(1, 0, 1, 0)
StreakBadge.BackgroundTransparency = 1
StreakBadge.Text = "Day 1"; StreakBadge.TextColor3 = Color3.fromRGB(60, 40, 0)
StreakBadge.Font = FONT; StreakBadge.TextSize = BADGE_FONT_SIZE
StreakBadge.ZIndex = 13; StreakBadge.Parent = StreakBadgeFrame

-- Dev-only close button (Studio only)
if RunService:IsStudio() then
	local CloseBtn = Instance.new("TextButton")
	CloseBtn.Name = "DevClose"
	CloseBtn.Size = UDim2.new(0, 28, 0, 28)
	CloseBtn.Position = UDim2.new(1, -34, 0, 7)
	CloseBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
	CloseBtn.BorderSizePixel = 0
	CloseBtn.Text = "X"; CloseBtn.TextColor3 = C.text
	CloseBtn.Font = FONT; CloseBtn.TextSize = 14
	CloseBtn.AutoButtonColor = true
	CloseBtn.ZIndex = 15; CloseBtn.Parent = Inner
	CloseBtn.MouseButton1Click:Connect(function()
		hideModal()
	end)
end

-- ============================================
-- DAY SLOTS — Single row of 7
-- ============================================
local DaysFrame = Instance.new("Frame")
DaysFrame.Name = "Days"
DaysFrame.Size = UDim2.new(1, 0, 0, SLOT_H + GRID_PAD * 2)
DaysFrame.Position = UDim2.new(0, 0, 0, GRID_Y)
DaysFrame.BackgroundTransparency = 1; DaysFrame.ZIndex = 11
DaysFrame:SetAttribute("KeepTransparent", true)
DaysFrame.Parent = Inner

-- Reward amounts are intentionally hidden from the UI - each claim is a surprise.

for i = 1, 7 do
	local xPos = GRID_PAD + (i - 1) * (SLOT_W + GRID_PAD)
	local yPos = GRID_PAD

	local slot = Instance.new("Frame")
	slot.Name = "Slot" .. i
	slot.Size = UDim2.new(0, SLOT_W, 0, SLOT_H)
	slot.Position = UDim2.new(0, xPos, 0, yPos)
	slot.BackgroundColor3 = C.slotLocked
	slot.BorderSizePixel = 0
	slot.ZIndex = 12; slot.Parent = DaysFrame
	local slotBevels = addBevel(slot, C.slotLockedBevelHL, C.slotLockedBevelSH, 3)

	-- Day label - text will be updated each week by updateDisplay() to show global day number
	local dayLabelSize = IsMobile and 14 or 12
	local dayLabel = Instance.new("TextLabel")
	dayLabel.Name = "DayLabel"
	dayLabel.Size = UDim2.new(1, 0, 0, 16)
	dayLabel.Position = UDim2.new(0, 0, 0, 2)
	dayLabel.BackgroundTransparency = 1
	dayLabel.Text = "Day " .. i
	dayLabel.TextColor3 = C.textDim; dayLabel.Font = FONT
	dayLabel.TextSize = dayLabelSize
	dayLabel.ZIndex = 13; dayLabel.Parent = slot

	DayFrames[i] = {
		slot = slot,
		bevels = slotBevels,
		dayLabel = dayLabel,
		-- Viewport data (populated once chest template loads)
		viewport = nil,
		chestModel = nil,
		hingeCF = nil,
		topCFs = nil,
	}
end

-- ============================================
-- DYNAMIC SLOT RELAYOUT
-- ============================================
-- Recomputes slot widths/positions, slot height, panel height, and the claim
-- button position from the Panel's CURRENT AbsoluteSize. Called once at startup
-- and whenever Panel.AbsoluteSize changes (e.g. when the viewport finally
-- initializes or the user rotates the device).
local relayoutInProgress = false
local function relayoutDays()
	if relayoutInProgress then return end -- prevent reentry from our own Panel.Size assignment
	local panelW = Panel.AbsoluteSize.X
	if panelW < 50 then return end -- ScreenGui not ready yet
	local innerWidth = panelW - 12 -- match Inner's -12 horizontal padding
	local actualSlotW = math.floor((innerWidth - GRID_PAD * (COLS + 1)) / COLS)
	if actualSlotW < 20 then return end -- guard against degenerate sizes
	
	relayoutInProgress = true
	
	-- Recompute height with the same aspect-ratio logic as module load
	local actualSlotH
	if IsMobile then
		actualSlotH = math.clamp(math.floor(actualSlotW * 1.15), 80, 140)
	else
		actualSlotH = 110
	end
	
	-- Recompute panel height to fit the actual slot height (mirrors the formula
	-- used at module load, but with the real slot height instead of a guess)
	local newPanelH = 12 + GRID_Y + actualSlotH + GRID_PAD * 2 + CLAIM_GAP + CLAIM_H + 18
	if IsMobile then
		Panel.Size = UDim2.new(1, -16, 0, newPanelH)
	else
		Panel.Size = UDim2.new(0, PANEL_WIDTH, 0, newPanelH)
	end
	
	-- Resize the days strip to fit the new slot height
	DaysFrame.Size = UDim2.new(1, 0, 0, actualSlotH + GRID_PAD * 2)
	
	-- Reposition / resize each slot
	for i = 1, 7 do
		local d = DayFrames[i]
		if d and d.slot then
			d.slot.Size = UDim2.new(0, actualSlotW, 0, actualSlotH)
			d.slot.Position = UDim2.new(0, GRID_PAD + (i - 1) * (actualSlotW + GRID_PAD), 0, GRID_PAD)
		end
	end
	
	-- The claim button sits below the days strip; reposition it to match
	if ClaimButton then
		local claimY = GRID_Y + actualSlotH + GRID_PAD * 2 + CLAIM_GAP
		ClaimButton.Position = UDim2.new(0, 0, 0, claimY)
	end
	
	relayoutInProgress = false
end

-- ============================================
-- CLAIM BUTTON
-- ============================================
local CLAIM_Y = GRID_Y + SLOT_H + GRID_PAD * 2 + CLAIM_GAP

local ClaimButton = Instance.new("TextButton")
ClaimButton.Name = "ClaimButton"
ClaimButton.Size = UDim2.new(1, 0, 0, CLAIM_H)
ClaimButton.Position = UDim2.new(0, 0, 0, CLAIM_Y)
ClaimButton.BackgroundColor3 = C.green; ClaimButton.BorderSizePixel = 0
ClaimButton.Text = ""; ClaimButton.AutoButtonColor = false
ClaimButton.ZIndex = 12; ClaimButton.Parent = Inner
local claimBevels = addBevel(ClaimButton, C.greenBevelHL, C.greenBevelSH)

local ClaimText = Instance.new("TextLabel")
ClaimText.Size = UDim2.new(1, 0, 1, 0); ClaimText.BackgroundTransparency = 1
ClaimText.Text = "Claim Reward!"; ClaimText.TextColor3 = C.text
ClaimText.Font = FONT; ClaimText.TextSize = IsMobile and 22 or 18
ClaimText.ZIndex = 13; ClaimText.Parent = ClaimButton

-- ============================================
-- POPULATE CHEST VIEWPORTS
-- ============================================
local function populateChestViewports()
	ChestTemplate = ReplicatedStorage:WaitForChild("BlockTemplates", 15)
		and ReplicatedStorage.BlockTemplates:FindFirstChild("SingleChest")

	if not ChestTemplate then
		warn("[BB-DR] SingleChest template not found")
		return
	end

	for i = 1, 7 do
		local d = DayFrames[i]
		local viewport, chest, hingeCF, topCFs = createChestViewport(d.slot, 14)
		d.viewport = viewport
		d.chestModel = chest
		d.hingeCF = hingeCF
		d.topCFs = topCFs
	end
end

-- ============================================
-- MODAL SHOW / HIDE
-- ============================================
local ModalShown = false

showModal = function()
	if ModalShown then return end
	ModalShown = true
	ScreenGui.Enabled = true

	BlurEffect.Size = 0
	BlurEffect.Parent = Lighting
	Overlay.BackgroundTransparency = 1

	TweenService:Create(Overlay, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = OVERLAY_TRANSPARENCY,
	}):Play()

	TweenService:Create(BlurEffect, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = BLUR_SIZE,
	}):Play()
end

hideModal = function()
	if not ModalShown then return end
	ModalShown = false

	TweenService:Create(Overlay, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		BackgroundTransparency = 1,
	}):Play()

	TweenService:Create(BlurEffect, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = 0,
	}):Play()

	for _, child in Panel:GetDescendants() do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			TweenService:Create(child, TweenInfo.new(0.4), {
				TextTransparency = 1, BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("ViewportFrame") then
			TweenService:Create(child, TweenInfo.new(0.4), {
				ImageTransparency = 1,
			}):Play()
		elseif child:IsA("ImageLabel") then
			TweenService:Create(child, TweenInfo.new(0.4), {
				ImageTransparency = 1, BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("Frame") then
			TweenService:Create(child, TweenInfo.new(0.4), {
				BackgroundTransparency = 1
			}):Play()
		end
	end
	TweenService:Create(Panel, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()

	task.delay(0.45, function()
		if not ModalShown then
			ScreenGui.Enabled = false
			BlurEffect.Parent = nil
		end
	end)
end

restorePanelVisuals = function()
	Panel.BackgroundTransparency = 0
	for _, child in Panel:GetDescendants() do
		if child:IsA("TextLabel") then
			child.TextTransparency = 0
		elseif child:IsA("TextButton") then
			child.TextTransparency = 0
			child.BackgroundTransparency = 0
		elseif child:IsA("ViewportFrame") then
			child.ImageTransparency = 0
		elseif child:IsA("Frame") then
			if child:GetAttribute("KeepTransparent") then
				-- Skip
			else
				local target = child:GetAttribute("TargetTransparency") or 0
				child.BackgroundTransparency = target
			end
		end
	end
end

-- ============================================
-- UPDATE DISPLAY
-- ============================================
local function setClaimState(enabled)
	if enabled then
		ClaimButton.BackgroundColor3 = C.green
		setBevel(claimBevels, C.greenBevelHL, C.greenBevelSH)
	else
		ClaimButton.BackgroundColor3 = C.disabledBtn
		setBevel(claimBevels, C.disabledBevelHL, C.disabledBevelSH)
	end
end

local function updateDisplay()
	if not DailyStatus then return end

	local currentDay = DailyStatus.currentDay or 1     -- 1-7 within current week (dayInWeek)
	local currentWeek = DailyStatus.currentWeek or 1   -- 1, 2, 3, ...
	local streak = DailyStatus.streak or 0             -- raw streak counter (can exceed 7)
	local canClaim = DailyStatus.canClaim
	
	-- How many days in the CURRENT visual week are already claimed.
	-- streak counts ALL days ever claimed, so subtract the days from previous weeks.
	local streakInWeek = math.max(0, streak - (currentWeek - 1) * 7)
	
	-- Global day offset for this week's slots (e.g. week 2 starts at day 8)
	local weekStartGlobalDay = (currentWeek - 1) * 7
	
	-- Update week badge
	WeekBadge.Text = "Week " .. currentWeek
	
	-- Refresh day labels (count up across weeks)
	for i = 1, 7 do
		local d = DayFrames[i]
		if d and d.dayLabel then
			d.dayLabel.Text = "Day " .. (weekStartGlobalDay + i)
		end
	end

	-- Streak badge shows the GLOBAL day number (e.g. "Day 8" in week 2 day 1)
	local globalCurrentDay = weekStartGlobalDay + currentDay
	StreakBadge.Text = "Day " .. globalCurrentDay
	if canClaim then
		StreakBadgeFrame.BackgroundColor3 = C.gold
		StreakBadge.TextColor3 = Color3.fromRGB(60, 40, 0)
	else
		StreakBadgeFrame.BackgroundColor3 = Color3.fromRGB(80, 70, 50)
		StreakBadge.TextColor3 = Color3.fromRGB(140, 120, 80)
	end

	for i = 1, 7 do
		local d = DayFrames[i]
		local isClaimed = (i <= streakInWeek)
		local isCurrent = (i == currentDay)

		if isClaimed then
			d.slot.BackgroundColor3 = C.slotClaimed
			setBevel(d.bevels, C.slotClaimedBevelHL, C.slotClaimedBevelSH)
			d.dayLabel.TextColor3 = Color3.fromRGB(80, 140, 80)
			-- Show open chest (this IS the "claimed" indicator - no checkmark)
			if d.viewport then
				d.viewport.ImageTransparency = 0
				if d.topCFs and d.hingeCF then
					setLidAngle(d.topCFs, d.hingeCF, math.rad(100))
				end
			end
		elseif isCurrent then
			d.slot.BackgroundColor3 = canClaim and C.slotCurrent or C.slotLocked
			if canClaim then
				setBevel(d.bevels, C.slotCurrentBevelHL, C.slotCurrentBevelSH)
			else
				setBevel(d.bevels, C.slotLockedBevelHL, C.slotLockedBevelSH)
			end
			d.dayLabel.TextColor3 = C.text
			-- Closed chest, full brightness
			if d.viewport then
				d.viewport.ImageTransparency = 0
				if d.topCFs and d.hingeCF then
					setLidAngle(d.topCFs, d.hingeCF, 0)
				end
			end
		else
			-- Future day (always reset to locked-gray; no per-day special-cases)
			d.slot.BackgroundColor3 = C.slotLocked
			setBevel(d.bevels, C.slotLockedBevelHL, C.slotLockedBevelSH)
			d.dayLabel.TextColor3 = Color3.fromRGB(70, 65, 65)
			-- Closed chest, dimmed
			if d.viewport then
				d.viewport.ImageTransparency = 0.5
				if d.topCFs and d.hingeCF then
					setLidAngle(d.topCFs, d.hingeCF, 0)
				end
			end
		end
	end

	-- Claim button state
	if canClaim then
		setClaimState(true)
		ClaimText.Text = "Claim Day " .. globalCurrentDay .. " Reward!"
		ClaimText.TextColor3 = C.text
	else
		setClaimState(false)
		ClaimText.Text = "Claimed!"
		ClaimText.TextColor3 = C.textDim
		if not IsClaiming then
			hideModal()
		end
	end
end

-- ============================================
-- CLAIM HANDLER
-- ============================================
local DEV_MODE = RunService:IsStudio()
local DevStreak = 0 -- Continuous streak counter for dev testing (keeps growing past 7)
local DevRng = Random.new()

local function onClaimClicked()
	if IsClaiming then return end
	if not DailyStatus or not DailyStatus.canClaim then return end
	IsClaiming = true; ClaimText.Text = "Claiming..."
	setClaimState(false)

	if DEV_MODE then
		-- Studio: advance streak and roll loot table for that day-in-week
		DevStreak = DevStreak + 1
		local claimedDay = ((DevStreak - 1) % 7) + 1
		local claimedWeek = math.ceil(DevStreak / 7)
		local coinReward = CoinConfig.RollDailyReward(claimedDay, claimedWeek, DevRng)

		-- Roll loot table (week-aware set chance)
		local setChance = LootConfig.GetSetChance(claimedDay, claimedWeek)
		local roll = DevRng:NextNumber()
		local gotSet = roll < setChance
		local rewardBlock = nil

		if not gotSet then
			print(string.format("[BB-DR] LOOT ROLL: COINS (%d) | W%d D%d setChance=%.0f%% | roll=%.2f",
				coinReward, claimedWeek, claimedDay, setChance * 100, roll))
		else
			-- Dev mode: pick from RewardSets folder with no ownership filter
			rewardBlock = RewardSetPicker.PickRandom(DevRng, nil)
			if rewardBlock then
				print(string.format("[BB-DR] LOOT ROLL: SET! %s (%s) | grants=%d | W%d D%d setChance=%.0f%% | roll=%.2f",
					rewardBlock.name, rewardBlock.rarity, #rewardBlock.grants, claimedWeek, claimedDay, setChance * 100, roll))
			else
				-- No folder or no models in it - fall back to coins for the preview
				gotSet = false
				print("[BB-DR] LOOT ROLL: SET! ...but ReplicatedStorage.RewardSets is empty, falling back to coins")
			end
		end

		local d = DayFrames[claimedDay]
		if d and d.chestModel then
			-- IMPORTANT: do NOT touch DailyStatus or call updateDisplay before the
			-- animation. updateDisplay would mark this slot as claimed and call
			-- setLidAngle(100deg) on its chest, which would then get cloned in that
			-- open state and break animateLidOpen's expectation of starting closed.
			animateChestClaim(d, coinReward, rewardBlock, function()
				-- Animation complete - now safely update the display.
				-- Push the post-claim state: the just-claimed day shows as claimed,
				-- the next-up day shows as current.
				local nextStreak = DevStreak + 1
				local nextDay = ((nextStreak - 1) % 7) + 1
				local nextWeek = math.ceil(nextStreak / 7)
				local nextGlobalDay = nextStreak  -- streak counter IS the global day number

				DailyStatus = {
					canClaim = true,
					currentDay = nextDay,
					dayInWeek = nextDay,
					currentWeek = nextWeek,
					streak = DevStreak,
				}
				updateDisplay()

				ClaimText.Text = "Claim Day " .. nextGlobalDay .. " Reward!"
				setClaimState(true)
				IsClaiming = false

				if nextDay == 1 then
					print(string.format("[BB-DR] === ENTERING WEEK %d ===", nextWeek))
				end
				print(string.format("[BB-DR] Next up: Week %d Day %d (global day %d)", nextWeek, nextDay, nextGlobalDay))
			end)
		else
			IsClaiming = false
			ClaimText.Text = "Claim Day " .. claimedDay .. " Reward!"
			setClaimState(true)
		end
		return
	end

	ClaimDailyReward:FireServer()
end

ClaimButton.MouseButton1Click:Connect(onClaimClicked)

ClaimButton.MouseEnter:Connect(function()
	if DailyStatus and DailyStatus.canClaim and not IsClaiming then
		ClaimButton.BackgroundColor3 = C.greenHover
	end
end)
ClaimButton.MouseLeave:Connect(function()
	if DailyStatus and DailyStatus.canClaim and not IsClaiming then
		ClaimButton.BackgroundColor3 = C.green
		setBevel(claimBevels, C.greenBevelHL, C.greenBevelSH)
	end
end)
ClaimButton.MouseButton1Down:Connect(function()
	if DailyStatus and DailyStatus.canClaim and not IsClaiming then
		ClaimButton.BackgroundColor3 = C.greenPress
		setBevel(claimBevels, C.greenBevelSH, C.greenBevelHL)
	end
end)
ClaimButton.MouseButton1Up:Connect(function()
	if DailyStatus and DailyStatus.canClaim and not IsClaiming then
		ClaimButton.BackgroundColor3 = C.greenHover
		setBevel(claimBevels, C.greenBevelHL, C.greenBevelSH)
	end
end)

DailyRewardResult.OnClientEvent:Connect(function(success, message, coinsAwarded, rewardSetInfo)
	if success then
		local claimedDay = DailyStatus and DailyStatus.currentDay or 1
		local reward = coinsAwarded or 0
		local d = DayFrames[claimedDay]

		-- If the server rolled a reward set, resolve the model from the folder for the burst
		local rewardBlock = nil
		if rewardSetInfo and rewardSetInfo.setName then
			local resolved = RewardSetPicker.GetSet(rewardSetInfo.setName)
			if resolved then
				rewardBlock = resolved
				print(string.format("[BB-DR] Server granted set '%s' (%s) | newly granted: %d block(s)",
					rewardSetInfo.setName, rewardSetInfo.rarity or "?",
					rewardSetInfo.newlyGranted and #rewardSetInfo.newlyGranted or 0))
			else
				warn(string.format("[BB-DR] Server granted set '%s' but no matching model in ReplicatedStorage.RewardBlocks", rewardSetInfo.setName))
			end
		end

		-- Animate the chest: shake then open
		if d and d.chestModel then
			animateChestClaim(d, reward, rewardBlock, function()
				-- The spotlight is now fading out (0.4s). Rather than restoring the
				-- daily-rewards modal for a couple of seconds with a slot flash and
				-- "Claimed!" text, we just dismiss the whole modal in parallel — the
				-- chest fades, the panel + blur fade, all in one continuous motion.
				IsClaiming = false

				-- Refresh DailyStatus in the background so it's up to date next time
				-- the modal opens. Runs concurrently with the fade; we don't wait on it.
				task.spawn(function()
					local ok, data = pcall(function() return GetCoinData:InvokeServer() end)
					if ok and data and data.dailyStatus then
						DailyStatus = data.dailyStatus
					end
				end)

				hideModal()
			end)
		else
			-- No chest model, just do basic visual
			IsClaiming = false
			ClaimText.Text = "Claimed!"
			task.spawn(function()
				task.wait(1.5)
				local ok, data = pcall(function() return GetCoinData:InvokeServer() end)
				if ok and data and data.dailyStatus then
					DailyStatus = data.dailyStatus
				end
				hideModal()
			end)
		end
	else
		IsClaiming = false
		ClaimText.Text = message or "Try again later"
		task.delay(2, function() updateDisplay() end)
	end
end)

-- ============================================
-- EXPOSE IsOpen FOR CAMERA CONTROLLER
-- ============================================
_G.DailyRewardsUI = {
	IsOpen = function()
		return ModalShown
	end,
}

-- ============================================
-- INITIAL DATA LOAD
-- ============================================
task.spawn(function()
	-- Wait for player to actually enter the game (click Creative)
	-- CSG assets for UnionOperations aren't render-ready until the 3D world is active
	print("[BB-DR] Waiting for game to start...")

	-- Poll for CameraController.GetGameStarted — this is set true
	-- only after the player clicks Creative and hideTitleScreen completes
	while true do
		if _G.CameraController and _G.CameraController.IsGameStarted and _G.CameraController.IsGameStarted() then
			break
		end
		task.wait(0.2)
	end

	print("[BB-DR] Game started, loading chests")
	print(string.format("[BB-DR] Viewport now: %.0f x %.0f | Panel AbsoluteSize: %.0f x %.0f",
		workspace.CurrentCamera.ViewportSize.X, workspace.CurrentCamera.ViewportSize.Y,
		Panel.AbsoluteSize.X, Panel.AbsoluteSize.Y))

	-- Ensure slots are sized correctly for the actual panel width
	relayoutDays()

	-- Load chest template for viewports (CSG assets available now)
	populateChestViewports()

	-- Re-relayout AFTER chest viewports exist (so they pick up the right slot sizes)
	task.wait()
	relayoutDays()

	print(string.format("[BB-DR] After relayout: Panel.AbsoluteSize = %.0f x %.0f (slot %.0f x %.0f)",
		Panel.AbsoluteSize.X, Panel.AbsoluteSize.Y,
		DayFrames[1] and DayFrames[1].slot and DayFrames[1].slot.AbsoluteSize.X or 0,
		DayFrames[1] and DayFrames[1].slot and DayFrames[1].slot.AbsoluteSize.Y or 0))

	-- Keep slots in sync if the panel ever resizes (rotation, viewport init delay, etc.)
	Panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayoutDays)

	-- Fetch daily status
	local ok, data = pcall(function() return GetCoinData:InvokeServer() end)
	if ok and data and data.dailyStatus then
		DailyStatus = data.dailyStatus
		if data.dailyStatus.canClaim then
			restorePanelVisuals()
			updateDisplay()
			showModal()
		end
	end
end)

-- Periodic check
task.spawn(function()
	while true do
		task.wait(60)
		if DailyStatus and not DailyStatus.canClaim then
			local ok, data = pcall(function() return GetCoinData:InvokeServer() end)
			if ok and data and data.dailyStatus then
				DailyStatus = data.dailyStatus
				if data.dailyStatus.canClaim and not ModalShown then
					restorePanelVisuals()
					updateDisplay()
					showModal()
				end
			end
		end
	end
end)

print("[DailyRewardsUI] Initialized (single-row chest viewport layout)")
