--[[
	ChunkLoadingScreen.client.luau
	FREE-BUILD (SECOND) PLACE ONLY.

	The free-build place builds a continuous chunk world around the player rather
	than the main game's "9 plots" boot sequence, so the plot-based
	WorldLoadingScreen doesn't apply here (it early-returns on this place). This
	screen covers the join until the player's CENTER chunk has finished spawning
	its blocks -- the moment they have real ground + immediate surrounding terrain
	under them. The outer 5x5 ring keeps filling in behind the world afterward.

	Signal: the server (ChunkTerrainManager.GenerateCenterChunk) sets the
	attribute ChunkCenterReady = true on the player's BuildArea once the center
	chunk's blocks exist. We find the BuildArea this player owns (OwnerUserId ==
	our UserId), then either read that attribute (already done) or wait for it via
	GetAttributeChangedSignal.

	Gating: this script only runs on free-build place IDs; everywhere else it
	bails immediately, leaving WorldLoadingScreen to handle the main game.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Free-build gate (single source of truth lives in BetaConfig). If the require
-- fails for any reason, fail SAFE by bailing -- better to show no screen than to
-- trap a main-game player behind a screen waiting for an attribute that never sets.
local BetaConfig
do
	local ok, mod = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("BetaConfig", 10))
	end)
	if not ok or not mod then return end
	BetaConfig = mod
end
if not BetaConfig.IsFreeBuildPlace() then
	return
end

-- ============================================
-- CONFIG
-- ============================================

local COLORS = {
	bg = Color3.fromRGB(20, 18, 18),
	barBg = Color3.fromRGB(50, 50, 50),
	barFill = Color3.fromRGB(76, 175, 80),
	barBorder = Color3.fromRGB(30, 30, 30),
	text = Color3.fromRGB(255, 255, 255),
	textShadow = Color3.fromRGB(60, 60, 60),
	subtitle = Color3.fromRGB(170, 170, 170),
}

-- Safety valve: if the readiness signal never arrives (server error, attribute
-- never set), drop the screen anyway after this long so the player is never
-- permanently stuck behind it.
local MAX_WAIT_SECONDS = 30

-- ============================================
-- STATE
-- ============================================

local screenGui = nil
local hidden = false

-- ============================================
-- UI
-- ============================================

local function createScreen()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ChunkLoadingScreen"
	screenGui.DisplayOrder = 99 -- behind title screen (100), above game UI
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = COLORS.bg
	bg.BorderSizePixel = 0
	bg.Parent = screenGui

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, 400, 0, 130)
	container.Position = UDim2.new(0.5, 0, 0.5, 0)
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.BackgroundTransparency = 1
	container.Parent = bg

	local titleShadow = Instance.new("TextLabel")
	titleShadow.Name = "TitleShadow"
	titleShadow.Size = UDim2.new(1, 0, 0, 40)
	titleShadow.Position = UDim2.new(0, 2, 0, 2)
	titleShadow.BackgroundTransparency = 1
	titleShadow.Font = Enum.Font.Arcade
	titleShadow.Text = "Building World..."
	titleShadow.TextSize = 32
	titleShadow.TextColor3 = COLORS.textShadow
	titleShadow.Parent = container

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 40)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.Arcade
	title.Text = "Building World..."
	title.TextSize = 32
	title.TextColor3 = COLORS.text
	title.Parent = container

	-- Indeterminate progress bar (we don't get block-level progress on this path,
	-- so a sweeping fill communicates "working" without a fake percentage).
	local barBorder = Instance.new("Frame")
	barBorder.Name = "BarBorder"
	barBorder.Size = UDim2.new(1, 0, 0, 24)
	barBorder.Position = UDim2.new(0, 0, 0, 55)
	barBorder.BackgroundColor3 = COLORS.barBorder
	barBorder.BorderSizePixel = 0
	barBorder.Parent = container

	local barBg = Instance.new("Frame")
	barBg.Name = "BarBg"
	barBg.Size = UDim2.new(1, -6, 1, -6)
	barBg.Position = UDim2.new(0, 3, 0, 3)
	barBg.BackgroundColor3 = COLORS.barBg
	barBg.BorderSizePixel = 0
	barBg.ClipsDescendants = true
	barBg.Parent = barBorder

	local barFill = Instance.new("Frame")
	barFill.Name = "BarFill"
	barFill.Size = UDim2.new(0.3, 0, 1, 0)
	barFill.Position = UDim2.new(-0.3, 0, 0, 0)
	barFill.BackgroundColor3 = COLORS.barFill
	barFill.BorderSizePixel = 0
	barFill.Parent = barBg

	-- Sweep the fill left->right on a loop until we hide.
	task.spawn(function()
		while screenGui and not hidden do
			barFill.Position = UDim2.new(-0.3, 0, 0, 0)
			local tween = TweenService:Create(
				barFill,
				TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
				{ Position = UDim2.new(1, 0, 0, 0) }
			)
			tween:Play()
			tween.Completed:Wait()
		end
	end)

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(1, 0, 0, 22)
	subtitle.Position = UDim2.new(0, 0, 0, 88)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.Arcade
	subtitle.Text = "Generating terrain..."
	subtitle.TextSize = 18
	subtitle.TextColor3 = COLORS.subtitle
	subtitle.Parent = container

	return screenGui
end

local function hideScreen()
	if hidden or not screenGui then return end
	hidden = true

	if _G._ChunkLoadingTitleWatch then
		_G._ChunkLoadingTitleWatch:Disconnect()
		_G._ChunkLoadingTitleWatch = nil
	end

	local container = screenGui:FindFirstChild("Background")
	if container then
		container = container:FindFirstChild("Container")
		if container then
			local subtitle = container:FindFirstChild("Subtitle")
			if subtitle then subtitle.Text = "Ready!" end
		end
	end

	task.wait(0.3)

	local bg = screenGui:FindFirstChild("Background")
	if bg then
		TweenService:Create(bg, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
		for _, desc in bg:GetDescendants() do
			if desc:IsA("TextLabel") then
				TweenService:Create(desc, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
			elseif desc:IsA("Frame") then
				TweenService:Create(desc, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
			end
		end
	end

	task.wait(0.6)
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end

	local titleScreen = playerGui:FindFirstChild("TitleScreen")
	if titleScreen then
		titleScreen.Enabled = true
	end
end

-- ============================================
-- FIND THE PLAYER'S BUILD AREA + WAIT FOR CENTER CHUNK
-- ============================================

-- The owned BuildArea is created server-side during assignPlot, which may not
-- have happened yet when this script runs. Poll briefly for the workspace child
-- whose OwnerUserId is ours.
local function findMyBuildArea()
	for _, child in ipairs(workspace:GetChildren()) do
		if child:IsA("Model")
			and child.Name:match("^BuildArea%d+$")
			and child:GetAttribute("OwnerUserId") == player.UserId then
			return child
		end
	end
	return nil
end

local function waitForMyBuildArea(timeoutSeconds)
	local deadline = os.clock() + timeoutSeconds
	local area = findMyBuildArea()
	while not area and os.clock() < deadline do
		task.wait(0.2)
		area = findMyBuildArea()
	end
	return area
end

-- ============================================
-- STARTUP
-- ============================================

createScreen()

-- Hide the title screen while we build (re-shown when the screen fades).
local titleScreen = playerGui:FindFirstChild("TitleScreen")
if titleScreen then
	titleScreen.Enabled = false
end
local titleWatch
titleWatch = playerGui.ChildAdded:Connect(function(child)
	if child.Name == "TitleScreen" and not hidden then
		child.Enabled = false
	end
end)
_G._ChunkLoadingTitleWatch = titleWatch

print("[ChunkLoadingScreen] Showing while center chunk generates")

-- Drive the wait in a thread so we can enforce the safety timeout.
task.spawn(function()
	local startedAt = os.clock()

	local buildArea = waitForMyBuildArea(MAX_WAIT_SECONDS)
	if not buildArea then
		print("[ChunkLoadingScreen] No owned BuildArea appeared; hiding (timeout)")
		hideScreen()
		return
	end

	-- Already ready (rejoin, or center generated faster than this script ran)?
	if buildArea:GetAttribute("ChunkCenterReady") == true then
		print("[ChunkLoadingScreen] Center chunk already ready")
		hideScreen()
		return
	end

	-- Otherwise wait for the attribute to flip true, with a safety timeout.
	local done = false
	local conn
	conn = buildArea:GetAttributeChangedSignal("ChunkCenterReady"):Connect(function()
		if buildArea:GetAttribute("ChunkCenterReady") == true and not done then
			done = true
			if conn then conn:Disconnect() end
			print("[ChunkLoadingScreen] Center chunk ready")
			hideScreen()
		end
	end)

	-- Safety: never trap the player. Remaining time after the buildArea appeared.
	local remaining = MAX_WAIT_SECONDS - (os.clock() - startedAt)
	if remaining < 5 then remaining = 5 end
	task.delay(remaining, function()
		if not done then
			done = true
			if conn then conn:Disconnect() end
			print("[ChunkLoadingScreen] Center chunk readiness timed out; hiding anyway")
			hideScreen()
		end
	end)
end)

print("[ChunkLoadingScreen] Initialized")
