--[[
	BroadcastUI.client.luau
	Displays broadcast messages in a BuildBlox / Minecraft-style banner that
	sits ABOVE the hotbar, matching its width.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ============================================================================
-- Hotbar dimensions (mirrors InventoryController so the banner aligns)
-- ============================================================================
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local HOTBAR_SLOTS = 10
local SLOT_SIZE = IsMobile and 48 or 58
local SLOT_PAD = 4
local HOTBAR_WIDTH = SLOT_SIZE * HOTBAR_SLOTS + SLOT_PAD * (HOTBAR_SLOTS - 1) + 8
local HOTBAR_HEIGHT = IsMobile and 60 or 70
local HOTBAR_BOTTOM_MARGIN = IsMobile and 8 or 12  -- gap between hotbar and screen bottom
local BANNER_GAP = 10  -- gap between banner bottom and hotbar top

-- Banner sizing
-- BANNER_HEIGHT is now a MINIMUM; the banner grows taller if the message wraps to multiple lines.
local BANNER_HEIGHT_MIN = IsMobile and 70 or 78
local HEADER_HEIGHT = IsMobile and 26 or 30
local BORDER_SIZE = 3
-- Padding around the message text inside the body
local MESSAGE_TOP_PAD = 3
local MESSAGE_BOTTOM_PAD = BORDER_SIZE + 3
local MESSAGE_SIDE_PAD = BORDER_SIZE + 8
local MESSAGE_TEXT_SIZE = IsMobile and 16 or 20

local DISPLAY_TIME = 8

-- ============================================================================
-- Colors (cardboard body + sky-blue header)
-- ============================================================================
local COLORS = {
	body = Color3.fromRGB(222, 196, 148),
	bodyHighlight = Color3.fromRGB(240, 218, 172),
	bodyShadow = Color3.fromRGB(180, 150, 102),
	header = Color3.fromRGB(96, 176, 232),
	headerHighlight = Color3.fromRGB(132, 202, 248),
	headerShadow = Color3.fromRGB(58, 124, 178),
	headerText = Color3.fromRGB(255, 255, 255),
	headerTextShadow = Color3.fromRGB(40, 70, 100),
	bodyText = Color3.fromRGB(45, 28, 14),
}

-- ============================================================================
-- Bevel helper (matches TitleScreen.addMinecraftBorder)
-- ============================================================================
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
-- ScreenGui
-- ============================================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "BroadcastUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 99  -- below the hotbar (DisplayOrder 100) so it doesn't overlap
screenGui.Parent = playerGui

-- Position the banner above the hotbar (bottom-anchored).
-- Hotbar top sits at: screen_bottom - HOTBAR_BOTTOM_MARGIN - HOTBAR_HEIGHT
-- Banner bottom sits at: hotbar_top - BANNER_GAP
local function bannerBottomYOffset()
	return -(HOTBAR_BOTTOM_MARGIN + HOTBAR_HEIGHT + BANNER_GAP)
end
-- Offscreen position must clear the full banner height + buffer so it slides in from below cleanly.
local function offscreenBottomYOffset(bannerHeight)
	return bannerHeight + 20
end

local function showBroadcast(data)
	local message = data.message or ""
	
	-- Measure the wrapped text so the banner can grow to fit multi-line messages.
	local messageAvailableWidth = HOTBAR_WIDTH - MESSAGE_SIDE_PAD * 2
	local textBounds = TextService:GetTextSize(
		message,
		MESSAGE_TEXT_SIZE,
		Enum.Font.Arcade,
		Vector2.new(messageAvailableWidth, 10000)
	)
	
	local minMessageHeight = BANNER_HEIGHT_MIN - HEADER_HEIGHT - MESSAGE_TOP_PAD - MESSAGE_BOTTOM_PAD
	-- +2px buffer because Arcade's pixel font occasionally undermeasures the trailing line.
	local messageHeight = math.max(minMessageHeight, textBounds.Y + 2)
	local bannerHeight = HEADER_HEIGHT + MESSAGE_TOP_PAD + messageHeight + MESSAGE_BOTTOM_PAD
	
	local finalY = bannerBottomYOffset()
	local startY = offscreenBottomYOffset(bannerHeight)
	
	-- Wrapper: bottom-anchored, centered horizontally, slides up from below.
	-- AnchorPoint (0.5, 1) means the bottom stays pinned to the hotbar; extra height grows upward.
	local wrapper = Instance.new("Frame")
	wrapper.Name = "BroadcastBanner"
	wrapper.Size = UDim2.new(0, HOTBAR_WIDTH, 0, bannerHeight)
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
	
	-- Sky-blue header strip
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	header.BackgroundColor3 = COLORS.header
	header.BorderSizePixel = 0
	header.ZIndex = 4
	header.Parent = body
	addBevel(header, COLORS.headerHighlight, COLORS.headerShadow, BORDER_SIZE)
	
	-- Header text shadow (1px down-right, fake pixel drop)
	local headerShadow2 = Instance.new("TextLabel")
	headerShadow2.Name = "HeaderShadow"
	headerShadow2.Size = UDim2.new(1, -22, 1, 0)
	headerShadow2.Position = UDim2.new(0, BORDER_SIZE + 8 + 1, 0, 2)
	headerShadow2.BackgroundTransparency = 1
	headerShadow2.Text = "ANNOUNCEMENT"
	headerShadow2.TextColor3 = COLORS.headerTextShadow
	headerShadow2.TextSize = IsMobile and 18 or 22
	headerShadow2.Font = Enum.Font.Arcade
	headerShadow2.TextXAlignment = Enum.TextXAlignment.Left
	headerShadow2.TextYAlignment = Enum.TextYAlignment.Center
	headerShadow2.ZIndex = 5
	headerShadow2.Parent = header
	
	-- Header text (main)
	local headerLabel = Instance.new("TextLabel")
	headerLabel.Name = "HeaderLabel"
	headerLabel.Size = UDim2.new(1, -22, 1, 0)
	headerLabel.Position = UDim2.new(0, BORDER_SIZE + 8, 0, 0)
	headerLabel.BackgroundTransparency = 1
	headerLabel.Text = "ANNOUNCEMENT"
	headerLabel.TextColor3 = COLORS.headerText
	headerLabel.TextSize = IsMobile and 18 or 22
	headerLabel.Font = Enum.Font.Arcade
	headerLabel.TextXAlignment = Enum.TextXAlignment.Left
	headerLabel.TextYAlignment = Enum.TextYAlignment.Center
	headerLabel.ZIndex = 6
	headerLabel.Parent = header
	
	-- Message body text — sized to the measured wrapped height (no truncation).
	local messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "Message"
	messageLabel.Size = UDim2.new(0, messageAvailableWidth, 0, messageHeight)
	messageLabel.Position = UDim2.new(0, MESSAGE_SIDE_PAD, 0, HEADER_HEIGHT + MESSAGE_TOP_PAD)
	messageLabel.BackgroundTransparency = 1
	messageLabel.Text = message
	messageLabel.TextColor3 = COLORS.bodyText
	messageLabel.TextSize = MESSAGE_TEXT_SIZE
	messageLabel.Font = Enum.Font.Arcade
	messageLabel.TextXAlignment = Enum.TextXAlignment.Left
	messageLabel.TextYAlignment = Enum.TextYAlignment.Top
	messageLabel.TextWrapped = true
	messageLabel.ZIndex = 4
	messageLabel.Parent = body
	
	-- Slide up from below
	local slideIn = TweenService:Create(
		wrapper,
		TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, 0, 1, finalY) }
	)
	slideIn:Play()
	
	-- Animate out after delay
	task.delay(DISPLAY_TIME, function()
		if not wrapper.Parent then return end
		local slideOut = TweenService:Create(
			wrapper,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = UDim2.new(0.5, 0, 1, startY) }
		)
		slideOut:Play()
		slideOut.Completed:Connect(function()
			wrapper:Destroy()
		end)
	end)
end

-- Listen for broadcast events
local BroadcastEvent = ReplicatedStorage:WaitForChild("BroadcastMessage", 30)
if BroadcastEvent then
	BroadcastEvent.OnClientEvent:Connect(function(data)
		showBroadcast(data)
	end)
	print("[BroadcastUI] Listening for broadcasts...")
else
	warn("[BroadcastUI] Could not find BroadcastMessage RemoteEvent")
end
