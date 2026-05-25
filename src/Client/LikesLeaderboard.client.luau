--[[
	LikesLeaderboard (Client)
	Replaces the default Roblox player list with a custom likes leaderboard
	Styled with Minecraft-style beveled edges to match the rest of the UI
	
	Mobile: Compact vertical strip on RIGHT side with avatars only
	Desktop: Full panel in top-right corner
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Mobile detection
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Disable default player list
local function disableDefaultLeaderboard()
	local success, err = pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)
	if not success then
		warn("[LikesLeaderboard] Failed to disable default playerlist: " .. tostring(err))
	end
end

-- Try multiple times in case it's not ready yet
task.spawn(function()
	for i = 1, 5 do
		disableDefaultLeaderboard()
		task.wait(1)
	end
end)

-- Wait for remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local RequestLeaderboard = Remotes:WaitForChild("RequestLeaderboard", 10)
local UpdateLeaderboard = Remotes:WaitForChild("UpdateLeaderboard", 10)
local LikeResult = Remotes:WaitForChild("LikeResult", 10)

-- ============================================
-- DARK MODE COLOR THEME (matches inventory)
-- ============================================
local COLORS = {
	Background = Color3.fromRGB(30, 30, 30),
	Surface = Color3.fromRGB(40, 40, 40),
	Header = Color3.fromRGB(35, 35, 35),
	Accent = Color3.fromRGB(255, 100, 100),       -- Heart/like color
	Text = Color3.fromRGB(220, 220, 220),
	TextMuted = Color3.fromRGB(140, 140, 140),
	Online = Color3.fromRGB(76, 175, 80),
	Gold = Color3.fromRGB(255, 215, 0),
	Silver = Color3.fromRGB(192, 192, 192),
	Bronze = Color3.fromRGB(205, 127, 50),
	Highlight = Color3.fromRGB(50, 50, 60),
	SlotBg = Color3.fromRGB(50, 50, 50),
}

local BEVEL_SIZE = 2

-- ============================================
-- BEVEL HELPERS (Minecraft-style 3D edges)
-- ============================================

-- Raised bevel: light top/left, dark bottom/right
local function addBevel(frame, highlightColor, shadowColor)
	local hl = highlightColor or Color3.fromRGB(80, 80, 80)
	local sh = shadowColor or Color3.fromRGB(0, 0, 0)

	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = hl
	top.BackgroundTransparency = 0.3
	top.BorderSizePixel = 0
	top.ZIndex = 5
	top.Parent = frame

	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = hl
	left.BackgroundTransparency = 0.3
	left.BorderSizePixel = 0
	left.ZIndex = 5
	left.Parent = frame

	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL_SIZE)
	bottom.BackgroundColor3 = sh
	bottom.BackgroundTransparency = 0.3
	bottom.BorderSizePixel = 0
	bottom.ZIndex = 5
	bottom.Parent = frame

	local right = Instance.new("Frame")
	right.Name = "BevelRight"
	right.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	right.Position = UDim2.new(1, -BEVEL_SIZE, 0, 0)
	right.BackgroundColor3 = sh
	right.BackgroundTransparency = 0.3
	right.BorderSizePixel = 0
	right.ZIndex = 5
	right.Parent = frame
end

-- Inset bevel: dark top/left, light bottom/right (for slots/entries)
local function addInsetBevel(frame, shadowColor, highlightColor)
	local sh = shadowColor or Color3.fromRGB(0, 0, 0)
	local hl = highlightColor or Color3.fromRGB(80, 80, 80)

	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = sh
	top.BackgroundTransparency = 0.3
	top.BorderSizePixel = 0
	top.ZIndex = 5
	top.Parent = frame

	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = sh
	left.BackgroundTransparency = 0.3
	left.BorderSizePixel = 0
	left.ZIndex = 5
	left.Parent = frame

	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL_SIZE)
	bottom.BackgroundColor3 = hl
	bottom.BackgroundTransparency = 0.3
	bottom.BorderSizePixel = 0
	bottom.ZIndex = 5
	bottom.Parent = frame

	local right = Instance.new("Frame")
	right.Name = "BevelRight"
	right.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	right.Position = UDim2.new(1, -BEVEL_SIZE, 0, 0)
	right.BackgroundColor3 = hl
	right.BackgroundTransparency = 0.3
	right.BorderSizePixel = 0
	right.ZIndex = 5
	right.Parent = frame
end

local currentLeaderboard = {}
local isVisible = true

-- ============================================
-- CREATE UI
-- ============================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LikesLeaderboardGui"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.ScreenInsets = Enum.ScreenInsets.None
screenGui.Parent = playerGui

local mainFrame, contentContainer, headerRow, headerTitle, headerLikes

if IsMobile then
	-- ============================================
	-- MOBILE LAYOUT: Compact vertical strip (blocky)
	-- ============================================
	
	local AVATAR_SIZE = 28
	local PADDING = 4
	local FRAME_SIZE = AVATAR_SIZE + (PADDING * 2)
	
	mainFrame = Instance.new("Frame")
	mainFrame.Name = "LeaderboardFrame"
	mainFrame.Size = UDim2.new(0, FRAME_SIZE, 0, 0)
	mainFrame.Position = UDim2.new(1, -FRAME_SIZE - 6, 0, 80) -- Below menu button
	mainFrame.BackgroundColor3 = COLORS.Background
	mainFrame.BackgroundTransparency = 0.2
	mainFrame.BorderSizePixel = 0
	mainFrame.Visible = true
	mainFrame.AutomaticSize = Enum.AutomaticSize.Y
	mainFrame.Parent = screenGui
	
	addBevel(mainFrame)
	
	contentContainer = Instance.new("Frame")
	contentContainer.Name = "ContentContainer"
	contentContainer.Size = UDim2.new(1, 0, 0, 0)
	contentContainer.BackgroundTransparency = 1
	contentContainer.AutomaticSize = Enum.AutomaticSize.Y
	contentContainer.Parent = mainFrame
	
	local containerPadding = Instance.new("UIPadding")
	containerPadding.PaddingTop = UDim.new(0, PADDING + BEVEL_SIZE)
	containerPadding.PaddingBottom = UDim.new(0, PADDING + BEVEL_SIZE)
	containerPadding.PaddingLeft = UDim.new(0, PADDING)
	containerPadding.PaddingRight = UDim.new(0, PADDING)
	containerPadding.Parent = contentContainer
	
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 4)
	listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	listLayout.Parent = contentContainer
	
else
	-- ============================================
	-- DESKTOP LAYOUT: Full panel (blocky beveled)
	-- ============================================
	
	mainFrame = Instance.new("Frame")
	mainFrame.Name = "LeaderboardFrame"
	mainFrame.Size = UDim2.new(0, 200, 0, 0)
	mainFrame.Position = UDim2.new(1, -210, 0, 46) -- Below menu button
	mainFrame.BackgroundColor3 = COLORS.Background
	mainFrame.BackgroundTransparency = 0.1
	mainFrame.BorderSizePixel = 0
	mainFrame.Visible = true
	mainFrame.AutomaticSize = Enum.AutomaticSize.Y
	mainFrame.Parent = screenGui
	
	-- Raised bevel on the outer panel
	addBevel(mainFrame)
	
	contentContainer = Instance.new("Frame")
	contentContainer.Name = "ContentContainer"
	contentContainer.Size = UDim2.new(1, 0, 0, 0)
	contentContainer.BackgroundTransparency = 1
	contentContainer.AutomaticSize = Enum.AutomaticSize.Y
	contentContainer.Parent = mainFrame
	
	local containerPadding = Instance.new("UIPadding")
	containerPadding.PaddingTop = UDim.new(0, 6 + BEVEL_SIZE)
	containerPadding.PaddingBottom = UDim.new(0, 6 + BEVEL_SIZE)
	containerPadding.PaddingLeft = UDim.new(0, 6 + BEVEL_SIZE)
	containerPadding.PaddingRight = UDim.new(0, 6 + BEVEL_SIZE)
	containerPadding.Parent = contentContainer
	
	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 3)
	listLayout.Parent = contentContainer
	
	-- Header row (inset bevel like a slot)
	headerRow = Instance.new("Frame")
	headerRow.Name = "Header"
	headerRow.Size = UDim2.new(1, 0, 0, 26)
	headerRow.BackgroundColor3 = COLORS.Header
	headerRow.BackgroundTransparency = 0
	headerRow.BorderSizePixel = 0
	headerRow.LayoutOrder = 0
	headerRow.Parent = contentContainer
	
	addInsetBevel(headerRow)
	
	headerTitle = Instance.new("TextLabel")
	headerTitle.Name = "Title"
	headerTitle.Size = UDim2.new(1, -50, 1, 0)
	headerTitle.Position = UDim2.new(0, 6, 0, 0)
	headerTitle.BackgroundTransparency = 1
	headerTitle.Text = "Players"
	headerTitle.TextSize = 14
	headerTitle.Font = Enum.Font.Arcade
	headerTitle.TextColor3 = COLORS.TextMuted
	headerTitle.TextXAlignment = Enum.TextXAlignment.Left
	headerTitle.Parent = headerRow
	
	headerLikes = Instance.new("TextLabel")
	headerLikes.Name = "Likes"
	headerLikes.Size = UDim2.new(0, 45, 1, 0)
	headerLikes.Position = UDim2.new(1, -51, 0, 0)
	headerLikes.BackgroundTransparency = 1
	headerLikes.Text = "Likes"
	headerLikes.TextSize = 14
	headerLikes.Font = Enum.Font.Arcade
	headerLikes.TextColor3 = COLORS.TextMuted
	headerLikes.TextXAlignment = Enum.TextXAlignment.Right
	headerLikes.Parent = headerRow
end


-- Notification frame (blocky style)
local notificationFrame = Instance.new("Frame")
notificationFrame.Name = "NotificationFrame"
notificationFrame.Size = UDim2.new(0, 280, 0, 45)
notificationFrame.Position = UDim2.new(0.5, -140, 0, -55)
notificationFrame.BackgroundColor3 = COLORS.Background
notificationFrame.BackgroundTransparency = 0.1
notificationFrame.BorderSizePixel = 0
notificationFrame.Visible = false
notificationFrame.Parent = screenGui

addBevel(notificationFrame)

local notifIcon = Instance.new("TextLabel")
notifIcon.Name = "Icon"
notifIcon.Size = UDim2.new(0, 40, 1, 0)
notifIcon.BackgroundTransparency = 1
notifIcon.Text = "❤️"
notifIcon.TextSize = 18
notifIcon.Font = Enum.Font.Arcade
notifIcon.Parent = notificationFrame

local notifText = Instance.new("TextLabel")
notifText.Name = "Text"
notifText.Size = UDim2.new(1, -50, 1, 0)
notifText.Position = UDim2.new(0, 42, 0, 0)
notifText.BackgroundTransparency = 1
notifText.Text = ""
notifText.TextSize = 13
notifText.Font = Enum.Font.Arcade
notifText.TextColor3 = COLORS.Text
notifText.TextXAlignment = Enum.TextXAlignment.Left
notifText.TextWrapped = true
notifText.Parent = notificationFrame

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function createPlayerEntry(rank, data)
	local isCurrentPlayer = data.userId == player.UserId
	
	if IsMobile then
		-- ============================================
		-- MOBILE ENTRY: Square avatar with like count badge
		-- ============================================
		
		local entrySize = 28
		
		local entry = Instance.new("Frame")
		entry.Name = "Entry_" .. rank
		entry.Size = UDim2.new(0, entrySize, 0, entrySize)
		entry.BackgroundColor3 = COLORS.SlotBg
		entry.BackgroundTransparency = 0
		entry.BorderSizePixel = 0
		entry.LayoutOrder = rank + 10
		
		addInsetBevel(entry)
		
		-- Avatar image (square, no rounded corners)
		local avatarImage = Instance.new("ImageLabel")
		avatarImage.Name = "Avatar"
		avatarImage.Size = UDim2.new(1, -BEVEL_SIZE * 2, 1, -BEVEL_SIZE * 2)
		avatarImage.Position = UDim2.new(0, BEVEL_SIZE, 0, BEVEL_SIZE)
		avatarImage.BackgroundTransparency = 1
		avatarImage.BorderSizePixel = 0
		avatarImage.Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(data.userId) .. "&w=150&h=150"
		avatarImage.Parent = entry
		
		-- Like count badge (bottom-right corner) - only show if has likes
		if data.totalLikes > 0 then
			local likeBadge = Instance.new("Frame")
			likeBadge.Name = "LikeBadge"
			likeBadge.Size = UDim2.new(0, 14, 0, 11)
			likeBadge.Position = UDim2.new(1, -14, 1, -11)
			likeBadge.BackgroundColor3 = COLORS.Accent
			likeBadge.BorderSizePixel = 0
			likeBadge.ZIndex = 6
			likeBadge.Parent = entry
			
			local likeText = Instance.new("TextLabel")
			likeText.Name = "Count"
			likeText.Size = UDim2.new(1, 0, 1, 0)
			likeText.BackgroundTransparency = 1
			likeText.Text = tostring(data.totalLikes)
			likeText.TextSize = 8
			likeText.Font = Enum.Font.Arcade
			likeText.TextColor3 = Color3.fromRGB(255, 255, 255)
			likeText.ZIndex = 7
			likeText.Parent = likeBadge
		end
		
		return entry
	else
		-- ============================================
		-- DESKTOP ENTRY: Full row with inset bevel
		-- ============================================
		
		local entry = Instance.new("Frame")
		entry.Name = "Entry_" .. rank
		entry.Size = UDim2.new(1, 0, 0, 30)
		entry.BackgroundColor3 = isCurrentPlayer and COLORS.Highlight or COLORS.SlotBg
		entry.BackgroundTransparency = 0
		entry.BorderSizePixel = 0
		entry.LayoutOrder = rank + 10
		
		addInsetBevel(entry)
		
		-- Player avatar icon (square)
		local avatarImage = Instance.new("ImageLabel")
		avatarImage.Name = "Avatar"
		avatarImage.Size = UDim2.new(0, 22, 0, 22)
		avatarImage.Position = UDim2.new(0, 5, 0.5, -11)
		avatarImage.BackgroundColor3 = COLORS.Background
		avatarImage.BorderSizePixel = 0
		avatarImage.Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(data.userId) .. "&w=150&h=150"
		avatarImage.Parent = entry
		
		-- Player name
		local nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "PlayerName"
		nameLabel.Size = UDim2.new(1, -75, 1, 0)
		nameLabel.Position = UDim2.new(0, 32, 0, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = data.displayName or data.username
		nameLabel.TextSize = 13
		nameLabel.Font = Enum.Font.Arcade
		nameLabel.TextColor3 = isCurrentPlayer and COLORS.Accent or COLORS.Text
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
		nameLabel.Parent = entry
		
		-- Likes count
		local likesLabel = Instance.new("TextLabel")
		likesLabel.Name = "Likes"
		likesLabel.Size = UDim2.new(0, 45, 1, 0)
		likesLabel.Position = UDim2.new(1, -51, 0, 0)
		likesLabel.BackgroundTransparency = 1
		likesLabel.Text = tostring(data.totalLikes or 0)
		likesLabel.TextSize = 13
		likesLabel.Font = Enum.Font.Arcade
		likesLabel.TextColor3 = data.totalLikes > 0 and COLORS.Accent or COLORS.TextMuted
		likesLabel.TextXAlignment = Enum.TextXAlignment.Right
		likesLabel.Parent = entry
		
		return entry
	end
end

local function refreshLeaderboard()
	-- Clear existing entries (but keep header)
	for _, child in ipairs(contentContainer:GetChildren()) do
		if child:IsA("Frame") and child.Name:match("^Entry_") then
			child:Destroy()
		end
	end
	
	-- Sort by likes
	local sorted = {}
	for _, data in ipairs(currentLeaderboard) do
		table.insert(sorted, data)
	end
	table.sort(sorted, function(a, b)
		return (a.totalLikes or 0) > (b.totalLikes or 0)
	end)
	
	-- Create entries
	for rank, data in ipairs(sorted) do
		local entry = createPlayerEntry(rank, data)
		entry.Parent = contentContainer
	end
	
	-- If no entries, show message (desktop only)
	if #sorted == 0 and not IsMobile then
		local emptyLabel = Instance.new("TextLabel")
		emptyLabel.Name = "Entry_Empty"
		emptyLabel.Size = UDim2.new(1, 0, 0, 30)
		emptyLabel.BackgroundTransparency = 1
		emptyLabel.Text = "No players"
		emptyLabel.TextSize = 13
		emptyLabel.Font = Enum.Font.Arcade
		emptyLabel.TextColor3 = COLORS.TextMuted
		emptyLabel.LayoutOrder = 10
		emptyLabel.Parent = contentContainer
	end
end

local function showNotification(message, isSuccess)
	notifText.Text = message
	notificationFrame.Position = UDim2.new(0.5, -140, 0, -55)
	notificationFrame.Visible = true
	
	-- Slide in
	local tweenIn = TweenService:Create(notificationFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, -140, 0, 15)
	})
	tweenIn:Play()
	
	-- Wait then slide out
	task.delay(3, function()
		local tweenOut = TweenService:Create(notificationFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, -140, 0, -55)
		})
		tweenOut:Play()
		tweenOut.Completed:Wait()
		notificationFrame.Visible = false
	end)
end

local function showLeaderboard()
	if isVisible then return end
	isVisible = true
	mainFrame.Visible = true
	
	-- Request fresh data
	RequestLeaderboard:FireServer()
end

local function hideLeaderboard()
	if not isVisible then return end
	isVisible = false
	mainFrame.Visible = false
end

-- ============================================
-- EVENT CONNECTIONS
-- ============================================

-- Tab key to toggle (desktop only)
if not IsMobile then
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		
		if input.KeyCode == Enum.KeyCode.Tab then
			if isVisible then
				hideLeaderboard()
			else
				showLeaderboard()
			end
		end
	end)
end

-- Receive leaderboard updates
UpdateLeaderboard.OnClientEvent:Connect(function(leaderboard)
	currentLeaderboard = leaderboard or {}
	refreshLeaderboard()
end)

-- Receive like results
LikeResult.OnClientEvent:Connect(function(success, message)
	showNotification(message, success)
end)

-- Backup request on player join
Players.PlayerAdded:Connect(function(newPlayer)
	task.delay(0.5, function()
		RequestLeaderboard:FireServer()
	end)
end)

Players.PlayerRemoving:Connect(function(leavingPlayer)
end)

-- ============================================
-- INITIALIZATION
-- ============================================

task.spawn(function()
	task.wait(0.5)
	RequestLeaderboard:FireServer()
end)

if IsMobile then
	print("[LikesLeaderboard] Initialized (Mobile) - Right-side compact view")
else
	print("[LikesLeaderboard] Initialized (Desktop) - Press Tab to toggle")
end
