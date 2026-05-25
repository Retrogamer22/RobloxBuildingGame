--[[
	UrgentShutdownUI
	Shows a countdown banner above the hotbar when the server is about to
	shut down. Uses the BuildBlox cardboard + beveled aesthetic.
	
	Supports optional style overrides via data.style table:
	- title (string)           : header text ("⚡ URGENT UPDATE REQUIRED" default)
	- countdownLabel (string)  : (unused in new layout — countdown is inline)
	- warningIcon (string)     : header icon ("⚠️" default)
	- accent ({r,g,b})         : header bg color (red default)
	- accentDark ({r,g,b})     : header shadow / bottom bevel
	- pulse (boolean)          : pulse countdown at low time (default true)
	
	If no style is provided, defaults match urgent (red) styling.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ============================================================================
-- Hotbar dimensions (mirrors InventoryController so banner aligns)
-- ============================================================================
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local HOTBAR_SLOTS = 10
local SLOT_SIZE = IsMobile and 48 or 58
local SLOT_PAD = 4
local HOTBAR_WIDTH = SLOT_SIZE * HOTBAR_SLOTS + SLOT_PAD * (HOTBAR_SLOTS - 1) + 8
local HOTBAR_HEIGHT = IsMobile and 60 or 70
local HOTBAR_BOTTOM_MARGIN = IsMobile and 8 or 12
local BANNER_GAP = 10

-- Banner sizing
local BANNER_HEIGHT = IsMobile and 70 or 78
local HEADER_HEIGHT = IsMobile and 26 or 30
local BORDER_SIZE = 3

-- ============================================================================
-- Default colors (URGENT style)
-- ============================================================================
local DEFAULT_ACCENT = Color3.fromRGB(220, 60, 60)
local DEFAULT_ACCENT_DARK = Color3.fromRGB(150, 40, 40)

local COLORS = {
	body = Color3.fromRGB(222, 196, 148),
	bodyHighlight = Color3.fromRGB(240, 218, 172),
	bodyShadow = Color3.fromRGB(180, 150, 102),
	headerText = Color3.fromRGB(255, 255, 255),
	bodyText = Color3.fromRGB(45, 28, 14),
	countdownWarn = Color3.fromRGB(255, 220, 80),  -- when pulsing low
}

local DEFAULT_TITLE = "URGENT UPDATE REQUIRED"

-- ============================================================================
-- Helpers
-- ============================================================================
local function resolveColor(override, fallback)
	if typeof(override) == "Color3" then return override end
	if type(override) == "table" and #override >= 3 then
		return Color3.fromRGB(override[1], override[2], override[3])
	end
	return fallback
end

local function lighten(color, amount)
	return Color3.fromRGB(
		math.min(255, math.floor(color.R * 255) + amount),
		math.min(255, math.floor(color.G * 255) + amount),
		math.min(255, math.floor(color.B * 255) + amount)
	)
end

local function darken(color, amount)
	return Color3.fromRGB(
		math.max(0, math.floor(color.R * 255) - amount),
		math.max(0, math.floor(color.G * 255) - amount),
		math.max(0, math.floor(color.B * 255) - amount)
	)
end

local function formatTime(seconds)
	local mins = math.floor(seconds / 60)
	local secs = seconds % 60
	if mins > 0 then
		return string.format("%d:%02d", mins, secs)
	end
	return tostring(secs)
end

-- 4-frame Minecraft-style bevel (matches TitleScreen.addMinecraftBorder)
local function addBevel(parent, highlightColor, shadowColor, thickness)
	local bs = thickness or BORDER_SIZE
	
	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, bs)
	top.BackgroundColor3 = highlightColor
	top.BorderSizePixel = 0
	top.ZIndex = parent.ZIndex + 1
	top.Parent = parent
	
	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, bs, 1, 0)
	left.BackgroundColor3 = highlightColor
	left.BorderSizePixel = 0
	left.ZIndex = parent.ZIndex + 1
	left.Parent = parent
	
	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, bs)
	bottom.Position = UDim2.new(0, 0, 1, -bs)
	bottom.BackgroundColor3 = shadowColor
	bottom.BorderSizePixel = 0
	bottom.ZIndex = parent.ZIndex + 1
	bottom.Parent = parent
	
	local right = Instance.new("Frame")
	right.Name = "BevelRight"
	right.Size = UDim2.new(0, bs, 1, 0)
	right.Position = UDim2.new(1, -bs, 0, 0)
	right.BackgroundColor3 = shadowColor
	right.BorderSizePixel = 0
	right.ZIndex = parent.ZIndex + 1
	right.Parent = parent
end

-- ============================================================================
-- Build the banner
-- ============================================================================
local function createShutdownUI(data)
	local countdown = data.countdown or 60
	local reason = data.reason or "A critical update is being deployed."
	local style = data.style or {}
	
	-- Resolve style with urgent defaults
	local titleText = style.title or DEFAULT_TITLE
	local headerColor = resolveColor(style.accent, DEFAULT_ACCENT)
	local headerShadowColor = resolveColor(style.accentDark, DEFAULT_ACCENT_DARK)
	local headerHighlightColor = lighten(headerColor, 35)
	local shouldPulse = style.pulse
	if shouldPulse == nil then shouldPulse = true end
	
	-- ScreenGui (recreate each call since shutdown UI is one-shot)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "UrgentShutdownUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 99  -- below hotbar (100) so doesn't overlap
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = playerGui
	
	-- Position
	local finalY = -(HOTBAR_BOTTOM_MARGIN + HOTBAR_HEIGHT + BANNER_GAP)
	local startY = 80
	
	-- Wrapper: bottom-anchored, slides up from below
	local wrapper = Instance.new("Frame")
	wrapper.Name = "ShutdownBanner"
	wrapper.Size = UDim2.new(0, HOTBAR_WIDTH, 0, BANNER_HEIGHT)
	wrapper.AnchorPoint = Vector2.new(0.5, 1)
	wrapper.Position = UDim2.new(0.5, 0, 1, startY)
	wrapper.BackgroundTransparency = 1
	wrapper.Parent = screenGui
	
	-- Body (cardboard) — fills the wrapper directly, no outer ring or drop shadow
	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = UDim2.new(1, 0, 1, 0)
	body.BackgroundColor3 = COLORS.body
	body.BorderSizePixel = 0
	body.ZIndex = 2
	body.Parent = wrapper
	addBevel(body, COLORS.bodyHighlight, COLORS.bodyShadow, BORDER_SIZE)
	
	-- Colored header (red urgent / blue soft / etc)
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	header.BackgroundColor3 = headerColor
	header.BorderSizePixel = 0
	header.ZIndex = 4
	header.Parent = body
	addBevel(header, headerHighlightColor, headerShadowColor, BORDER_SIZE)
	
	-- Title text + shadow
	local titleShadow = Instance.new("TextLabel")
	titleShadow.Name = "TitleShadow"
	titleShadow.Size = UDim2.new(1, -100, 1, 0)
	titleShadow.Position = UDim2.new(0, BORDER_SIZE + 8 + 1, 0, 2)
	titleShadow.BackgroundTransparency = 1
	titleShadow.Text = titleText
	titleShadow.TextColor3 = darken(headerColor, 70)
	titleShadow.TextSize = IsMobile and 16 or 20
	titleShadow.Font = Enum.Font.Arcade
	titleShadow.TextXAlignment = Enum.TextXAlignment.Left
	titleShadow.TextYAlignment = Enum.TextYAlignment.Center
	titleShadow.TextTruncate = Enum.TextTruncate.AtEnd
	titleShadow.ZIndex = 5
	titleShadow.Parent = header
	
	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -100, 1, 0)
	titleLabel.Position = UDim2.new(0, BORDER_SIZE + 8, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = titleText
	titleLabel.TextColor3 = COLORS.headerText
	titleLabel.TextSize = IsMobile and 16 or 20
	titleLabel.Font = Enum.Font.Arcade
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextYAlignment = Enum.TextYAlignment.Center
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	titleLabel.ZIndex = 6
	titleLabel.Parent = header
	
	-- Countdown time (right-aligned in header)
	local countdownLabel = Instance.new("TextLabel")
	countdownLabel.Name = "Countdown"
	countdownLabel.Size = UDim2.new(0, 80, 1, 0)
	countdownLabel.Position = UDim2.new(1, -80 - BORDER_SIZE - 6, 0, 0)
	countdownLabel.BackgroundTransparency = 1
	countdownLabel.Text = formatTime(countdown)
	countdownLabel.TextColor3 = COLORS.headerText
	countdownLabel.TextSize = IsMobile and 18 or 22
	countdownLabel.Font = Enum.Font.Arcade
	countdownLabel.TextXAlignment = Enum.TextXAlignment.Right
	countdownLabel.TextYAlignment = Enum.TextYAlignment.Center
	countdownLabel.ZIndex = 6
	countdownLabel.Parent = header
	
	-- Reason text (body)
	local reasonLabel = Instance.new("TextLabel")
	reasonLabel.Name = "Reason"
	reasonLabel.Size = UDim2.new(1, -BORDER_SIZE * 2 - 16, 1, -HEADER_HEIGHT - BORDER_SIZE - 6)
	reasonLabel.Position = UDim2.new(0, BORDER_SIZE + 8, 0, HEADER_HEIGHT + 3)
	reasonLabel.BackgroundTransparency = 1
	reasonLabel.Text = reason
	reasonLabel.TextColor3 = COLORS.bodyText
	reasonLabel.TextSize = IsMobile and 16 or 20
	reasonLabel.Font = Enum.Font.Arcade
	reasonLabel.TextXAlignment = Enum.TextXAlignment.Left
	reasonLabel.TextYAlignment = Enum.TextYAlignment.Top
	reasonLabel.TextWrapped = true
	reasonLabel.TextTruncate = Enum.TextTruncate.AtEnd
	reasonLabel.ZIndex = 4
	reasonLabel.Parent = body
	
	-- Slide up from below
	local slideIn = TweenService:Create(
		wrapper,
		TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 1, finalY) }
	)
	slideIn:Play()
	
	-- Countdown loop
	local isPulsing = false
	local function startPulse()
		if isPulsing then return end
		isPulsing = true
		task.spawn(function()
			while isPulsing and countdownLabel.Parent do
				local pulseOut = TweenService:Create(countdownLabel, TweenInfo.new(0.3),
					{ TextColor3 = COLORS.countdownWarn })
				pulseOut:Play()
				pulseOut.Completed:Wait()
				if not (isPulsing and countdownLabel.Parent) then break end
				local pulseIn = TweenService:Create(countdownLabel, TweenInfo.new(0.3),
					{ TextColor3 = COLORS.headerText })
				pulseIn:Play()
				pulseIn.Completed:Wait()
			end
		end)
	end
	
	task.spawn(function()
		local remaining = countdown
		while remaining > 0 and screenGui.Parent do
			countdownLabel.Text = formatTime(remaining)
			if shouldPulse and remaining <= 10 and not isPulsing then
				startPulse()
			end
			if remaining <= 5 then
				countdownLabel.TextSize = IsMobile and 20 or 26
			end
			task.wait(1)
			remaining = remaining - 1
		end
		countdownLabel.Text = "..."
		countdownLabel.TextColor3 = COLORS.countdownWarn
		isPulsing = false
	end)
end

-- ============================================================================
-- Listen for shutdown events
-- ============================================================================
local UrgentShutdown = ReplicatedStorage:WaitForChild("UrgentShutdown", 30)
if UrgentShutdown then
	UrgentShutdown.OnClientEvent:Connect(function(data)
		print("[UrgentShutdownUI] Received shutdown notification!")
		print("[UrgentShutdownUI] Countdown:", data.countdown, "seconds")
		print("[UrgentShutdownUI] Reason:", data.reason)
		
		-- Remove any existing shutdown UI
		local existing = playerGui:FindFirstChild("UrgentShutdownUI")
		if existing then existing:Destroy() end
		
		createShutdownUI(data)
	end)
	print("[UrgentShutdownUI] Listening for urgent shutdown notifications...")
else
	warn("[UrgentShutdownUI] UrgentShutdown RemoteEvent not found")
end
