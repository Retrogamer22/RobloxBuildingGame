--[[
	TipToasts
	Shows helpful tips to new players during their first 5 minutes of gameplay
	Tips stay visible until the player performs the action
	
	Positioned directly below the player list (LikesLeaderboard)
	Styled as Minecraft advancement-style toasts with bevels
	On mobile: above the compact player icon strip on the right
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Check if player has already seen tips
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local GetTipsSeen = Remotes and Remotes:WaitForChild("GetTipsSeen", 10)
local MarkTipsSeen = Remotes and Remotes:WaitForChild("MarkTipsSeen", 10)

if GetTipsSeen then
	local success, alreadySeen = pcall(function()
		return GetTipsSeen:InvokeServer()
	end)
	if success and alreadySeen then
		print("[TipToasts] Player has already seen tips, skipping")
		return
	end
end

-- Configuration
local CONFIG = {
	TIP_DURATION = 5 * 60,
	NEXT_TIP_DELAY = 2,
	INITIAL_DELAY = 3,
	SLIDE_IN_TIME = 0.4,
	SLIDE_OUT_TIME = 0.3,
}

-- Mobile detection
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Colors matched to LikesLeaderboard dark theme
local MC_PANEL = Color3.fromRGB(30, 30, 30)           -- matches COLORS.Background
local MC_PANEL_BORDER = Color3.fromRGB(15, 15, 15)
local MC_BEVEL_LIGHT = Color3.fromRGB(80, 80, 80)     -- matches leaderboard bevel
local MC_BEVEL_DARK = Color3.fromRGB(0, 0, 0)         -- matches leaderboard bevel
local MC_TEXT = Color3.fromRGB(255, 255, 85)           -- MC gold text for advancement toasts
local MC_TEXT_SHADOW = Color3.fromRGB(60, 60, 20)
local MC_TEXT_SUB = Color3.fromRGB(220, 220, 220)      -- matches COLORS.Text
local MC_TEXT_SUB_SHADOW = Color3.fromRGB(55, 55, 55)
local BEVEL = 2

-- State
local CurrentTipIndex = 0
local ToastGui = nil
local ToastFrame = nil
local TitleLabel = nil
local TitleShadow = nil
local TextLabel = nil
local TextShadow = nil
local IsShowingToast = false
local TipsEnabled = true
local CurrentTip = nil
local TipCompleteCallback = nil

-- ============================================
-- MC BEVEL HELPER
-- ============================================

local function addRaisedBevel(frame, lightColor, darkColor)
	local hl = lightColor or MC_BEVEL_LIGHT
	local sh = darkColor or MC_BEVEL_DARK
	local top = Instance.new("Frame")
	top.Name = "BevelTop"; top.Size = UDim2.new(1, 0, 0, BEVEL)
	top.BackgroundColor3 = hl; top.BackgroundTransparency = 0.2; top.BorderSizePixel = 0; top.ZIndex = 5; top.Parent = frame
	local left = Instance.new("Frame")
	left.Name = "BevelLeft"; left.Size = UDim2.new(0, BEVEL, 1, 0)
	left.BackgroundColor3 = hl; left.BackgroundTransparency = 0.2; left.BorderSizePixel = 0; left.ZIndex = 5; left.Parent = frame
	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"; bottom.Size = UDim2.new(1, 0, 0, BEVEL); bottom.Position = UDim2.new(0, 0, 1, -BEVEL)
	bottom.BackgroundColor3 = sh; bottom.BackgroundTransparency = 0.2; bottom.BorderSizePixel = 0; bottom.ZIndex = 5; bottom.Parent = frame
	local right = Instance.new("Frame")
	right.Name = "BevelRight"; right.Size = UDim2.new(0, BEVEL, 1, 0); right.Position = UDim2.new(1, -BEVEL, 0, 0)
	right.BackgroundColor3 = sh; right.BackgroundTransparency = 0.2; right.BorderSizePixel = 0; right.ZIndex = 5; right.Parent = frame
end

-- ============================================
-- UI CREATION
-- ============================================

local function createToastUI()
	ToastGui = Instance.new("ScreenGui")
	ToastGui.Name = "TipToastsGui"
	ToastGui.ResetOnSpawn = false
	ToastGui.ScreenInsets = Enum.ScreenInsets.None
	ToastGui.DisplayOrder = 50
	ToastGui.Parent = PlayerGui

	local toastWidth = IsMobile and 200 or 200

	-- Toast frame (starts off-screen to the right)
	ToastFrame = Instance.new("Frame")
	ToastFrame.Name = "ToastFrame"
	ToastFrame.AnchorPoint = Vector2.new(0, 0)
	-- Start hidden off-screen (slideIn will set real position)
	ToastFrame.Position = UDim2.new(1, 300, 0, 0)
	ToastFrame.Size = UDim2.new(0, toastWidth, 0, 66)
	ToastFrame.BackgroundColor3 = MC_PANEL
	ToastFrame.BackgroundTransparency = 0
	ToastFrame.BorderSizePixel = 0
	ToastFrame.Visible = false
	ToastFrame.Parent = ToastGui

	addRaisedBevel(ToastFrame)

	-- Inner border (1px dark line inside the bevel, like MC advancement toasts)
	local innerBorder = Instance.new("Frame")
	innerBorder.Name = "InnerBorder"
	innerBorder.Size = UDim2.new(1, -BEVEL * 2 - 4, 1, -BEVEL * 2 - 4)
	innerBorder.Position = UDim2.new(0, BEVEL + 2, 0, BEVEL + 2)
	innerBorder.BackgroundTransparency = 1
	innerBorder.BorderSizePixel = 0
	innerBorder.Parent = ToastFrame

	local innerStroke = Instance.new("UIStroke")
	innerStroke.Color = MC_PANEL_BORDER
	innerStroke.Thickness = 1
	innerStroke.Parent = innerBorder

	-- Title ("Tip!" in gold)
	TitleShadow = Instance.new("TextLabel")
	TitleShadow.Name = "TitleShadow"
	TitleShadow.Size = UDim2.new(1, -16, 0, 18)
	TitleShadow.Position = UDim2.new(0, 10, 0, 6)
	TitleShadow.BackgroundTransparency = 1
	TitleShadow.Font = Enum.Font.Arcade
	TitleShadow.TextSize = 14
	TitleShadow.TextColor3 = MC_TEXT_SHADOW
	TitleShadow.TextXAlignment = Enum.TextXAlignment.Left
	TitleShadow.Text = "Tip!"
	TitleShadow.ZIndex = 6
	TitleShadow.Parent = ToastFrame

	TitleLabel = Instance.new("TextLabel")
	TitleLabel.Name = "Title"
	TitleLabel.Size = UDim2.new(1, -16, 0, 18)
	TitleLabel.Position = UDim2.new(0, 8, 0, 4)
	TitleLabel.BackgroundTransparency = 1
	TitleLabel.Font = Enum.Font.Arcade
	TitleLabel.TextSize = 14
	TitleLabel.TextColor3 = MC_TEXT
	TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
	TitleLabel.Text = "Tip!"
	TitleLabel.ZIndex = 7
	TitleLabel.Parent = ToastFrame

	-- Tip text (white, below title)
	TextShadow = Instance.new("TextLabel")
	TextShadow.Name = "TextShadow"
	TextShadow.Size = UDim2.new(1, -16, 0, 38)
	TextShadow.Position = UDim2.new(0, 10, 0, 26)
	TextShadow.BackgroundTransparency = 1
	TextShadow.Font = Enum.Font.Arcade
	TextShadow.TextSize = 13
	TextShadow.TextColor3 = MC_TEXT_SUB_SHADOW
	TextShadow.TextXAlignment = Enum.TextXAlignment.Left
	TextShadow.TextWrapped = true
	TextShadow.Text = ""
	TextShadow.ZIndex = 6
	TextShadow.Parent = ToastFrame

	TextLabel = Instance.new("TextLabel")
	TextLabel.Name = "Text"
	TextLabel.Size = UDim2.new(1, -16, 0, 38)
	TextLabel.Position = UDim2.new(0, 8, 0, 24)
	TextLabel.BackgroundTransparency = 1
	TextLabel.Font = Enum.Font.Arcade
	TextLabel.TextSize = 13
	TextLabel.TextColor3 = MC_TEXT_SUB
	TextLabel.TextXAlignment = Enum.TextXAlignment.Left
	TextLabel.TextWrapped = true
	TextLabel.Text = ""
	TextLabel.ZIndex = 7
	TextLabel.Parent = ToastFrame

	return ToastGui
end

local function resizeToastToFit()
	if not TextLabel then return end
	local w = ToastFrame.Size.X.Offset
	-- Temporarily make text label very tall so TextBounds measures full wrapped text
	TextLabel.Size = UDim2.new(1, -16, 0, 200)
	TextShadow.Size = UDim2.new(1, -16, 0, 200)
	task.defer(function()
		if not TextLabel then return end
		local textH = TextLabel.TextBounds.Y
		local needed = math.max(56, TextLabel.Position.Y.Offset + textH + 8)
		ToastFrame.Size = UDim2.new(0, w, 0, needed)
		-- Set text labels to match measured height
		TextLabel.Size = UDim2.new(1, -16, 0, textH + 4)
		TextShadow.Size = UDim2.new(1, -16, 0, textH + 4)
	end)
end

-- ============================================
-- POSITION TRACKING (below player list)
-- ============================================

local leaderboardFrame = nil
local ToastWrapper = nil

local function findLeaderboard()
	local lbGui = PlayerGui:FindFirstChild("LikesLeaderboardGui")
	if lbGui then
		leaderboardFrame = lbGui:FindFirstChild("LeaderboardFrame")
	end
end

-- Leaderboard desktop: Position = UDim2.new(1, -210, 0, 10), Size = 200px wide, AutomaticSize.Y
local LB_X_OFFSET = -210
local TOAST_WIDTH = IsMobile and 200 or 200
local leaderboardReady = false

-- Called after createToastUI() to set up wrapper + heartbeat tracking
local function initPositionTracking()
	-- Wrapper frame sits at leaderboard's X, Y tracks leaderboard bottom
	ToastWrapper = Instance.new("Frame")
	ToastWrapper.Name = "ToastWrapper"
	ToastWrapper.Size = UDim2.new(0, TOAST_WIDTH, 0, 60)
	ToastWrapper.Position = UDim2.new(1, LB_X_OFFSET, 0, 120)
	ToastWrapper.BackgroundTransparency = 1
	ToastWrapper.ClipsDescendants = false
	ToastWrapper.Parent = ToastGui

	-- Reparent toast frame inside the wrapper
	ToastFrame.AnchorPoint = Vector2.new(0, 0)
	ToastFrame.Position = UDim2.new(0, TOAST_WIDTH + 20, 0, 0)
	ToastFrame.Parent = ToastWrapper

	-- Every frame: keep wrapper Y pinned to leaderboard bottom
	RunService.Heartbeat:Connect(function()
		if not leaderboardFrame then
			findLeaderboard()
		end
		if leaderboardFrame and leaderboardFrame.Visible then
			local lbBottom = leaderboardFrame.AbsolutePosition.Y + leaderboardFrame.AbsoluteSize.Y + 70
			ToastWrapper.Position = UDim2.new(1, LB_X_OFFSET, 0, lbBottom)
			if leaderboardFrame.AbsoluteSize.Y > 30 then
				leaderboardReady = true
			end
		end
	end)
end

-- ============================================
-- TOAST ANIMATIONS (slide in from right)
-- ============================================

local function slideIn()
	ToastFrame.Visible = true
	-- Start outside wrapper to the right
	ToastFrame.Position = UDim2.new(0, TOAST_WIDTH + 20, 0, 0)
	local tween = TweenService:Create(ToastFrame, TweenInfo.new(CONFIG.SLIDE_IN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0, 0, 0, 0)
	})
	tween:Play()
	return tween
end

local function slideOut()
	local tween = TweenService:Create(ToastFrame, TweenInfo.new(CONFIG.SLIDE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = UDim2.new(0, TOAST_WIDTH + 20, 0, 0)
	})
	tween:Play()
	return tween
end

-- ============================================
-- TIP COMPLETION
-- ============================================

local function completeTip()
	if not IsShowingToast then return end
	IsShowingToast = false
	TipCompleteCallback = nil

	local tween = slideOut()
	tween.Completed:Wait()
	ToastFrame.Visible = false
	CurrentTip = nil
end

-- ============================================
-- TIP DEFINITIONS
-- ============================================

local function createDesktopTips()
	return {
		{
			text = "Press E to open your inventory",
			setup = function(onComplete)
				local conn
				conn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
					if input.KeyCode == Enum.KeyCode.E then
						conn:Disconnect()
						onComplete()
					end
				end)
				return conn
			end,
		},
		{
			text = "Right-click to place, hold left-click to break",
			setup = function(onComplete)
				local hasPlaced = false
				local hasBroken = false
				local function checkComplete()
					if hasPlaced and hasBroken then
						_G.OnBlockPlaced = nil
						_G.OnBlockBroken = nil
						onComplete()
					end
				end
				_G.OnBlockPlaced = function() hasPlaced = true; checkComplete() end
				_G.OnBlockBroken = function() hasBroken = true; checkComplete() end
				return { Disconnect = function() _G.OnBlockPlaced = nil; _G.OnBlockBroken = nil end }
			end,
		},
		{
			text = "Scroll wheel cycles hotbar slots",
			setup = function(onComplete)
				local conn
				conn = UserInputService.InputChanged:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseWheel then
						conn:Disconnect()
						onComplete()
					end
				end)
				return conn
			end,
		},
		{
			text = "Double-tap Space to toggle flight",
			setup = function(onComplete)
				local running = true
				task.spawn(function()
					while running and TipsEnabled do
						if _G.FlightController and _G.FlightController.IsFlying and _G.FlightController.IsFlying() then
							running = false; onComplete(); break
						end
						task.wait(0.1)
					end
				end)
				return { Disconnect = function() running = false end }
			end,
		},
		{
			text = "Right-click a hotbar slot to clear it",
			setup = function(onComplete)
				local conn
				conn = UserInputService.InputBegan:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton2 then
						conn:Disconnect(); onComplete()
					end
				end)
				return conn
			end,
		},
	}
end

local function createMobileTips()
	return {
		{
			text = "Tap inventory button to open it",
			setup = function(onComplete)
				local running = true
				task.spawn(function()
					while running and TipsEnabled do
						if _G.InventoryController and _G.InventoryController.IsInventoryOpen and _G.InventoryController.IsInventoryOpen() then
							running = false; onComplete(); break
						end
						task.wait(0.1)
					end
				end)
				return { Disconnect = function() running = false end }
			end,
		},
		{
			text = "Tap to place blocks, hold to break",
			setup = function(onComplete)
				local hasPlaced = false
				local hasBroken = false
				local function checkComplete()
					if hasPlaced and hasBroken then
						_G.OnBlockPlaced = nil; _G.OnBlockBroken = nil; onComplete()
					end
				end
				_G.OnBlockPlaced = function() hasPlaced = true; checkComplete() end
				_G.OnBlockBroken = function() hasBroken = true; checkComplete() end
				return { Disconnect = function() _G.OnBlockPlaced = nil; _G.OnBlockBroken = nil end }
			end,
		},
		{
			text = "Swipe on hotbar to change slots",
			setup = function(onComplete)
				local lastSlot = _G.InventoryController and _G.InventoryController.GetCurrentSlot and _G.InventoryController.GetCurrentSlot() or 1
				local running = true
				task.spawn(function()
					while running and TipsEnabled do
						local s = _G.InventoryController and _G.InventoryController.GetCurrentSlot and _G.InventoryController.GetCurrentSlot() or 1
						if s ~= lastSlot then running = false; onComplete(); break end
						task.wait(0.1)
					end
				end)
				return { Disconnect = function() running = false end }
			end,
		},
		{
			text = "Double-tap fly button to toggle flight",
			setup = function(onComplete)
				local conn
				conn = UserInputService.TouchEnded:Connect(function()
					conn:Disconnect(); task.wait(2); onComplete()
				end)
				return conn
			end,
		},
	}
end

local Tips = IsMobile and createMobileTips() or createDesktopTips()

-- ============================================
-- TIP DISPLAY
-- ============================================

local CurrentConnection = nil

local function showTip(tip)
	if IsShowingToast then return end
	IsShowingToast = true
	CurrentTip = tip

	TextLabel.Text = tip.text
	TextShadow.Text = tip.text
	resizeToastToFit()

	slideIn()

	CurrentConnection = tip.setup(function()
		if CurrentConnection then
			if CurrentConnection.Disconnect then CurrentConnection:Disconnect() end
			CurrentConnection = nil
		end
		completeTip()
	end)
end

-- ============================================
-- TIP CYCLING
-- ============================================

local function getNextTip()
	CurrentTipIndex = CurrentTipIndex + 1
	if CurrentTipIndex > #Tips then return nil end
	return Tips[CurrentTipIndex]
end

local function startTipCycle()
	task.wait(CONFIG.INITIAL_DELAY)

	-- Wait until the polling loop has captured a valid leaderboard position
	for i = 1, 20 do
		if leaderboardReady then break end
		task.wait(0.3)
	end
	-- Extra frame for layout to fully settle
	task.wait(0.5)

	local startTime = tick()

	while TipsEnabled and (tick() - startTime) < CONFIG.TIP_DURATION do
		local tip = getNextTip()
		if not tip then break end

		showTip(tip)

		while IsShowingToast and TipsEnabled do
			task.wait(0.1)
		end

		if not TipsEnabled then break end
		task.wait(CONFIG.NEXT_TIP_DELAY)
	end

	task.wait(1)
	if ToastGui then ToastGui:Destroy() end

	-- Mark tips as seen so they don't show again
	if MarkTipsSeen then
		pcall(function()
			MarkTipsSeen:FireServer()
		end)
	end

	print("[TipToasts] All tips completed, marked as seen")
end

-- ============================================
-- PUBLIC API
-- ============================================

local function stopTips()
	TipsEnabled = false
	if CurrentConnection then
		if CurrentConnection.Disconnect then CurrentConnection:Disconnect() end
		CurrentConnection = nil
	end
	if IsShowingToast then completeTip() end
	
	-- Mark tips as seen when stopped early too
	if MarkTipsSeen then
		pcall(function()
			MarkTipsSeen:FireServer()
		end)
	end
end

local function showCustomTip(text, duration)
	if not ToastGui or not ToastFrame then return end

	if IsShowingToast then
		if CurrentConnection then
			if CurrentConnection.Disconnect then CurrentConnection:Disconnect() end
			CurrentConnection = nil
		end
		completeTip()
		task.wait(CONFIG.SLIDE_OUT_TIME + 0.1)
	end

	IsShowingToast = true
	TextLabel.Text = text
	TextShadow.Text = text
	resizeToastToFit()
	slideIn()

	if duration then
		task.delay(duration, function()
			if IsShowingToast and TextLabel.Text == text then
				IsShowingToast = false
				local tween = slideOut()
				tween.Completed:Wait()
				ToastFrame.Visible = false
			end
		end)
	end
end

-- ============================================
-- INITIALIZATION
-- ============================================

createToastUI()
initPositionTracking()
task.spawn(startTipCycle)

_G.TipToasts = {
	Stop = stopTips,
	ShowTip = showCustomTip,
}

print("[TipToasts] Initialized - MC toast style")
