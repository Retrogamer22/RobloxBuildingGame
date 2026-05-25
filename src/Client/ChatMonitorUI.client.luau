--[[
	ChatMonitorUI
	Displays a one-way chat transcript for the game owner.
	Shows messages from all players in a collapsible panel.
]]

-- Feature toggle - set to false to disable
local ENABLED = false
if not ENABLED then return end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Wait for remote (only exists if server created it)
local ChatMonitorRemote = ReplicatedStorage:WaitForChild("ChatMonitorRemote", 5)
if not ChatMonitorRemote then
	-- Not the owner, exit silently
	return
end

-- Check if we're the owner by waiting for a test message or just proceeding
-- The server only sends to the owner anyway, so if we receive messages, we're the owner

-- Configuration
local COLORS = {
	panelBg = Color3.fromRGB(25, 25, 35),
	headerBg = Color3.fromRGB(35, 35, 48),
	messageBg = Color3.fromRGB(40, 40, 55),
	text = Color3.fromRGB(255, 255, 255),
	subtext = Color3.fromRGB(160, 160, 170),
	username = Color3.fromRGB(100, 200, 255),
	accent = Color3.fromRGB(80, 180, 120),
	timestamp = Color3.fromRGB(120, 120, 130),
}

local MAX_MESSAGES = 50
local isExpanded = false
local isVisible = true
local messageCount = 0

-- Create the UI
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ChatMonitorUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 100
screenGui.Parent = playerGui

-- Main panel (collapsed by default)
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.new(0, 320, 0, 40) -- Collapsed size
panel.Position = UDim2.new(0, 10, 0.5, -150)
panel.BackgroundColor3 = COLORS.panelBg
panel.BorderSizePixel = 0
panel.ClipsDescendants = true
panel.Parent = screenGui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 8)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = Color3.fromRGB(60, 60, 75)
panelStroke.Thickness = 1
panelStroke.Parent = panel

-- Header (always visible)
local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 40)
header.BackgroundColor3 = COLORS.headerBg
header.BorderSizePixel = 0
header.Parent = panel

local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 8)
headerCorner.Parent = header

-- Cover bottom corners of header when expanded
local headerCover = Instance.new("Frame")
headerCover.Size = UDim2.new(1, 0, 0, 10)
headerCover.Position = UDim2.new(0, 0, 1, -10)
headerCover.BackgroundColor3 = COLORS.headerBg
headerCover.BorderSizePixel = 0
headerCover.Visible = false
headerCover.Parent = header

-- Title
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.new(0, 12, 0, 0)
title.BackgroundTransparency = 1
title.Text = "🔊 Chat Monitor"
title.TextColor3 = COLORS.text
title.TextSize = 14
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

-- Message count badge
local badge = Instance.new("TextLabel")
badge.Name = "Badge"
badge.Size = UDim2.new(0, 24, 0, 18)
badge.Position = UDim2.new(0, 125, 0.5, -9)
badge.BackgroundColor3 = COLORS.accent
badge.Text = "0"
badge.TextColor3 = COLORS.text
badge.TextSize = 11
badge.Font = Enum.Font.GothamBold
badge.Visible = false
badge.Parent = header

local badgeCorner = Instance.new("UICorner")
badgeCorner.CornerRadius = UDim.new(0, 6)
badgeCorner.Parent = badge

-- Toggle button
local toggleButton = Instance.new("TextButton")
toggleButton.Name = "Toggle"
toggleButton.Size = UDim2.new(0, 30, 0, 30)
toggleButton.Position = UDim2.new(1, -70, 0.5, -15)
toggleButton.BackgroundTransparency = 1
toggleButton.Text = "▼"
toggleButton.TextColor3 = COLORS.subtext
toggleButton.TextSize = 14
toggleButton.Font = Enum.Font.GothamBold
toggleButton.Parent = header

-- Hide button
local hideButton = Instance.new("TextButton")
hideButton.Name = "Hide"
hideButton.Size = UDim2.new(0, 30, 0, 30)
hideButton.Position = UDim2.new(1, -38, 0.5, -15)
hideButton.BackgroundTransparency = 1
hideButton.Text = "✕"
hideButton.TextColor3 = COLORS.subtext
hideButton.TextSize = 14
hideButton.Font = Enum.Font.GothamBold
hideButton.Parent = header

-- Hover effects
toggleButton.MouseEnter:Connect(function()
	toggleButton.TextColor3 = COLORS.text
end)
toggleButton.MouseLeave:Connect(function()
	toggleButton.TextColor3 = COLORS.subtext
end)
hideButton.MouseEnter:Connect(function()
	hideButton.TextColor3 = COLORS.text
end)
hideButton.MouseLeave:Connect(function()
	hideButton.TextColor3 = COLORS.subtext
end)

-- Messages container
local messagesFrame = Instance.new("ScrollingFrame")
messagesFrame.Name = "Messages"
messagesFrame.Size = UDim2.new(1, -16, 1, -50)
messagesFrame.Position = UDim2.new(0, 8, 0, 44)
messagesFrame.BackgroundTransparency = 1
messagesFrame.BorderSizePixel = 0
messagesFrame.ScrollBarThickness = 4
messagesFrame.ScrollBarImageColor3 = COLORS.accent
messagesFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
messagesFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
messagesFrame.ScrollingDirection = Enum.ScrollingDirection.Y
messagesFrame.Parent = panel

local messagesLayout = Instance.new("UIListLayout")
messagesLayout.SortOrder = Enum.SortOrder.LayoutOrder
messagesLayout.Padding = UDim.new(0, 4)
messagesLayout.Parent = messagesFrame

-- Empty state
local emptyLabel = Instance.new("TextLabel")
emptyLabel.Name = "Empty"
emptyLabel.Size = UDim2.new(1, 0, 0, 60)
emptyLabel.BackgroundTransparency = 1
emptyLabel.Text = "No messages yet...\nChat will appear here"
emptyLabel.TextColor3 = COLORS.subtext
emptyLabel.TextSize = 12
emptyLabel.Font = Enum.Font.Gotham
emptyLabel.Parent = messagesFrame

-- Show/hide indicator (when panel is hidden)
local showIndicator = Instance.new("TextButton")
showIndicator.Name = "ShowIndicator"
showIndicator.Size = UDim2.new(0, 36, 0, 36)
showIndicator.Position = UDim2.new(0, 10, 0.5, -150)
showIndicator.BackgroundColor3 = COLORS.panelBg
showIndicator.Text = "🔊"
showIndicator.TextSize = 18
showIndicator.BorderSizePixel = 0
showIndicator.Visible = false
showIndicator.Parent = screenGui

local showCorner = Instance.new("UICorner")
showCorner.CornerRadius = UDim.new(0, 8)
showCorner.Parent = showIndicator

local showStroke = Instance.new("UIStroke")
showStroke.Color = Color3.fromRGB(60, 60, 75)
showStroke.Thickness = 1
showStroke.Parent = showIndicator

-- Notification dot on show indicator
local indicatorDot = Instance.new("Frame")
indicatorDot.Name = "Dot"
indicatorDot.Size = UDim2.new(0, 12, 0, 12)
indicatorDot.Position = UDim2.new(1, -6, 0, -4)
indicatorDot.BackgroundColor3 = Color3.fromRGB(255, 90, 90)
indicatorDot.BorderSizePixel = 0
indicatorDot.Visible = false
indicatorDot.Parent = showIndicator

local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent = indicatorDot

-- Track message order
local messageOrder = 0

-- Add a message to the panel
local function addMessage(data)
	emptyLabel.Visible = false
	messageOrder = messageOrder + 1
	messageCount = messageCount + 1
	
	-- Update badge
	if not isExpanded then
		badge.Text = tostring(messageCount)
		badge.Visible = messageCount > 0
		
		-- Also show dot on hidden indicator
		if not isVisible then
			indicatorDot.Visible = true
		end
	end
	
	-- Create message frame
	local msgFrame = Instance.new("Frame")
	msgFrame.Name = "Msg" .. messageOrder
	msgFrame.Size = UDim2.new(1, -8, 0, 0) -- Auto-size height
	msgFrame.AutomaticSize = Enum.AutomaticSize.Y
	msgFrame.BackgroundColor3 = COLORS.messageBg
	msgFrame.BorderSizePixel = 0
	msgFrame.LayoutOrder = messageOrder
	msgFrame.Parent = messagesFrame
	
	local msgCorner = Instance.new("UICorner")
	msgCorner.CornerRadius = UDim.new(0, 6)
	msgCorner.Parent = msgFrame
	
	local msgPadding = Instance.new("UIPadding")
	msgPadding.PaddingTop = UDim.new(0, 6)
	msgPadding.PaddingBottom = UDim.new(0, 6)
	msgPadding.PaddingLeft = UDim.new(0, 8)
	msgPadding.PaddingRight = UDim.new(0, 8)
	msgPadding.Parent = msgFrame
	
	-- Header line (username + time)
	local headerLine = Instance.new("Frame")
	headerLine.Size = UDim2.new(1, 0, 0, 16)
	headerLine.BackgroundTransparency = 1
	headerLine.Parent = msgFrame
	
	local usernameLabel = Instance.new("TextLabel")
	usernameLabel.Size = UDim2.new(1, -50, 1, 0)
	usernameLabel.BackgroundTransparency = 1
	usernameLabel.Text = data.displayName .. " (@" .. data.username .. ")"
	usernameLabel.TextColor3 = COLORS.username
	usernameLabel.TextSize = 11
	usernameLabel.Font = Enum.Font.GothamBold
	usernameLabel.TextXAlignment = Enum.TextXAlignment.Left
	usernameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	usernameLabel.Parent = headerLine
	
	local timeLabel = Instance.new("TextLabel")
	timeLabel.Size = UDim2.new(0, 45, 1, 0)
	timeLabel.Position = UDim2.new(1, -45, 0, 0)
	timeLabel.BackgroundTransparency = 1
	timeLabel.Text = os.date("%H:%M", data.timestamp)
	timeLabel.TextColor3 = COLORS.timestamp
	timeLabel.TextSize = 10
	timeLabel.Font = Enum.Font.Gotham
	timeLabel.TextXAlignment = Enum.TextXAlignment.Right
	timeLabel.Parent = headerLine
	
	-- Message text
	local messageLabel = Instance.new("TextLabel")
	messageLabel.Size = UDim2.new(1, 0, 0, 0)
	messageLabel.AutomaticSize = Enum.AutomaticSize.Y
	messageLabel.Position = UDim2.new(0, 0, 0, 18)
	messageLabel.BackgroundTransparency = 1
	messageLabel.Text = data.message
	messageLabel.TextColor3 = COLORS.text
	messageLabel.TextSize = 13
	messageLabel.Font = Enum.Font.Gotham
	messageLabel.TextXAlignment = Enum.TextXAlignment.Left
	messageLabel.TextYAlignment = Enum.TextYAlignment.Top
	messageLabel.TextWrapped = true
	messageLabel.Parent = msgFrame
	
	-- Limit messages
	local messages = {}
	for _, child in ipairs(messagesFrame:GetChildren()) do
		if child:IsA("Frame") then
			table.insert(messages, child)
		end
	end
	
	if #messages > MAX_MESSAGES then
		-- Remove oldest
		table.sort(messages, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		messages[1]:Destroy()
	end
	
	-- Auto-scroll to bottom
	task.defer(function()
		messagesFrame.CanvasPosition = Vector2.new(0, messagesFrame.AbsoluteCanvasSize.Y)
	end)
end

-- Toggle expand/collapse
local function toggleExpand()
	isExpanded = not isExpanded
	
	if isExpanded then
		-- Expand
		TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 320, 0, 300)
		}):Play()
		toggleButton.Text = "▲"
		headerCover.Visible = true
		
		-- Clear badge
		messageCount = 0
		badge.Visible = false
	else
		-- Collapse
		TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 320, 0, 40)
		}):Play()
		toggleButton.Text = "▼"
		headerCover.Visible = false
	end
end

-- Hide/show panel
local function hidePanel()
	isVisible = false
	panel.Visible = false
	showIndicator.Visible = true
end

local function showPanel()
	isVisible = true
	panel.Visible = true
	showIndicator.Visible = false
	indicatorDot.Visible = false
end

-- Connect buttons
toggleButton.MouseButton1Click:Connect(toggleExpand)
header.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		toggleExpand()
	end
end)
hideButton.MouseButton1Click:Connect(hidePanel)
showIndicator.MouseButton1Click:Connect(showPanel)

-- Keybind: Ctrl+M to toggle visibility
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	
	if input.KeyCode == Enum.KeyCode.M then
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
			if isVisible then
				hidePanel()
			else
				showPanel()
			end
		end
	end
end)

-- Listen for messages from server
ChatMonitorRemote.OnClientEvent:Connect(function(data)
	addMessage(data)
end)

print("[ChatMonitorUI] Initialized - Press Ctrl+M to toggle visibility")
