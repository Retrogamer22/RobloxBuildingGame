--[[
	PlayerInteractionUI
	Client-side UI for right-clicking on players to access plot sharing/blocking options
	Minecraft-style UI that sits above the hotbar
	
	Features:
	- Right-click on player to open interaction menu
	- Long-press on mobile as alternative to right-click
	- Contextual buttons based on relationship:
	  - Share Plot (if Roblox friend and not already shared)
	  - Revoke Access (if already shared)
	  - Kick from Plot (if target is on your plot)
	  - Block from Plot (always available)
	  - Unblock (if already blocked)
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- Wait for remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local SharePlotAccess = Remotes:WaitForChild("SharePlotAccess", 5)
local RevokePlotAccess = Remotes:WaitForChild("RevokePlotAccess", 5)
local BlockFromPlot = Remotes:WaitForChild("BlockFromPlot", 5)
local UnblockFromPlot = Remotes:WaitForChild("UnblockFromPlot", 5)
local KickFromPlot = Remotes:WaitForChild("KickFromPlot", 5)
local GetPlayerInteractionInfo = Remotes:WaitForChild("GetPlayerInteractionInfo", 5)
local PlotPermissionResult = Remotes:WaitForChild("PlotPermissionResult", 5)

-- Configuration
local PlotPermissionConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PlotPermissionConfig"))

-- Mobile detection
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Constants
local MAX_INTERACTION_DISTANCE = 50
local LONG_PRESS_TIME = 0.5

-- Minecraft-style colors (matches inventory theme)
local MC = {
	PanelBg = Color3.fromRGB(139, 139, 139),        -- Classic MC stone grey
	PanelDark = Color3.fromRGB(85, 85, 85),          -- Darker panel areas
	SlotBg = Color3.fromRGB(110, 110, 110),          -- Inset slot background
	BevelLight = Color3.fromRGB(200, 200, 200),      -- Light bevel edge
	BevelDark = Color3.fromRGB(55, 55, 55),          -- Dark bevel edge
	InsetLight = Color3.fromRGB(160, 160, 160),      -- Inset light edge
	InsetDark = Color3.fromRGB(70, 70, 70),          -- Inset dark edge
	Text = Color3.fromRGB(63, 63, 63),               -- Dark text on grey
	TextWhite = Color3.fromRGB(255, 255, 255),       -- White text (for buttons)
	TextShadow = Color3.fromRGB(40, 40, 40),         -- Text shadow
	TextGold = Color3.fromRGB(255, 255, 85),         -- MC gold/yellow text
	TextGreen = Color3.fromRGB(85, 255, 85),         -- MC green
	TextRed = Color3.fromRGB(255, 85, 85),           -- MC red
	ButtonGreen = Color3.fromRGB(76, 175, 80),       -- Green button
	ButtonGreenHover = Color3.fromRGB(96, 200, 100), -- Green button hover
	ButtonRed = Color3.fromRGB(180, 60, 60),         -- Red button
	ButtonRedHover = Color3.fromRGB(210, 80, 80),    -- Red button hover
	ButtonOrange = Color3.fromRGB(200, 140, 50),     -- Orange button
	ButtonOrangeHover = Color3.fromRGB(225, 165, 70),-- Orange button hover
	ButtonNeutral = Color3.fromRGB(120, 120, 120),   -- Neutral button
	ButtonNeutralHover = Color3.fromRGB(145, 145, 145),
}

local BEVEL = 3 -- Bevel thickness in pixels

-- State
local currentTargetPlayer = nil
local isUIOpen = false
local longPressStartTime = nil
local longPressTarget = nil

-- ============================================
-- MINECRAFT BEVEL HELPERS (matches inventory)
-- ============================================

local function addRaisedBevel(frame, lightColor, darkColor)
	local hl = lightColor or MC.BevelLight
	local sh = darkColor or MC.BevelDark

	-- Top highlight
	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = hl
	top.BackgroundTransparency = 0.3
	top.BorderSizePixel = 0
	top.ZIndex = 5
	top.Parent = frame

	-- Left highlight
	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, BEVEL, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = hl
	left.BackgroundTransparency = 0.3
	left.BorderSizePixel = 0
	left.ZIndex = 5
	left.Parent = frame

	-- Bottom shadow
	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL)
	bottom.BackgroundColor3 = sh
	bottom.BackgroundTransparency = 0.3
	bottom.BorderSizePixel = 0
	bottom.ZIndex = 5
	bottom.Parent = frame

	-- Right shadow
	local right = Instance.new("Frame")
	right.Name = "BevelRight"
	right.Size = UDim2.new(0, BEVEL, 1, 0)
	right.Position = UDim2.new(1, -BEVEL, 0, 0)
	right.BackgroundColor3 = sh
	right.BackgroundTransparency = 0.3
	right.BorderSizePixel = 0
	right.ZIndex = 5
	right.Parent = frame
end

local function addInsetBevel(frame)
	local sh = MC.InsetDark
	local hl = MC.InsetLight

	-- Top shadow (inset = dark on top)
	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = sh
	top.BackgroundTransparency = 0.2
	top.BorderSizePixel = 0
	top.ZIndex = 5
	top.Parent = frame

	-- Left shadow
	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, BEVEL, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = sh
	left.BackgroundTransparency = 0.2
	left.BorderSizePixel = 0
	left.ZIndex = 5
	left.Parent = frame

	-- Bottom highlight (inset = light on bottom)
	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL)
	bottom.BackgroundColor3 = hl
	bottom.BackgroundTransparency = 0.2
	bottom.BorderSizePixel = 0
	bottom.ZIndex = 5
	bottom.Parent = frame

	-- Right highlight
	local right = Instance.new("Frame")
	right.Name = "BevelRight"
	right.Size = UDim2.new(0, BEVEL, 1, 0)
	right.Position = UDim2.new(1, -BEVEL, 0, 0)
	right.BackgroundColor3 = hl
	right.BackgroundTransparency = 0.2
	right.BorderSizePixel = 0
	right.ZIndex = 5
	right.Parent = frame
end

-- Helper to create MC-style text with drop shadow
local function createShadowedText(parent, props)
	-- Shadow label (offset down-right by 2px)
	local shadow = Instance.new("TextLabel")
	shadow.Name = (props.Name or "Label") .. "Shadow"
	shadow.Size = props.Size or UDim2.new(1, 0, 1, 0)
	shadow.Position = (props.Position or UDim2.new(0, 0, 0, 0)) + UDim2.new(0, 2, 0, 2)
	shadow.BackgroundTransparency = 1
	shadow.Font = props.Font or Enum.Font.Arcade
	shadow.TextSize = props.TextSize or 14
	shadow.TextColor3 = MC.TextShadow
	shadow.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	shadow.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	shadow.Text = props.Text or ""
	shadow.ZIndex = (props.ZIndex or 1)
	shadow.Parent = parent

	-- Main label
	local label = Instance.new("TextLabel")
	label.Name = props.Name or "Label"
	label.Size = props.Size or UDim2.new(1, 0, 1, 0)
	label.Position = props.Position or UDim2.new(0, 0, 0, 0)
	label.BackgroundTransparency = 1
	label.Font = props.Font or Enum.Font.Arcade
	label.TextSize = props.TextSize or 14
	label.TextColor3 = props.TextColor3 or MC.TextWhite
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	label.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	label.Text = props.Text or ""
	label.ZIndex = (props.ZIndex or 1) + 1
	label.Parent = parent

	return label, shadow
end

-- ============================================
-- UI CREATION
-- ============================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PlayerInteractionUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 150
screenGui.Enabled = true
screenGui.Parent = playerGui

-- Calculate position above hotbar
-- Hotbar is ~70px tall, ~12px from bottom edge
-- We want the popup to sit right above that
local panelWidth = IsMobile and 320 or 380
local panelHeight = IsMobile and 150 or 170
local hotbarHeight = IsMobile and 60 or 70
local hotbarBottomGap = IsMobile and 8 or 12
local gapAboveHotbar = 8

-- Main container - positioned above the hotbar, anchored at bottom-center
local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, panelWidth, 0, panelHeight)
mainFrame.AnchorPoint = Vector2.new(0.5, 1)
-- Resting position: just above hotbar
-- Y = 1 scale - hotbarHeight - hotbarBottomGap - gapAboveHotbar
local targetY = -(hotbarHeight + hotbarBottomGap + gapAboveHotbar)
mainFrame.Position = UDim2.new(0.5, 0, 1, targetY + panelHeight + 20) -- Start hidden below
mainFrame.BackgroundColor3 = MC.PanelBg
mainFrame.BackgroundTransparency = 0
mainFrame.BorderSizePixel = 0
mainFrame.Visible = false
mainFrame.Parent = screenGui

-- Outer raised bevel on main panel
addRaisedBevel(mainFrame)

-- 1px black border
-- No stroke on main panel - bevels provide the border

-- ============================================
-- HEADER (player info area - inset)
-- ============================================

local headerFrame = Instance.new("Frame")
headerFrame.Name = "Header"
headerFrame.Size = UDim2.new(1, -16, 0, 52)
headerFrame.Position = UDim2.new(0, 8, 0, 8)
headerFrame.BackgroundColor3 = MC.SlotBg
headerFrame.BackgroundTransparency = 0
headerFrame.BorderSizePixel = 0
headerFrame.Parent = mainFrame

addInsetBevel(headerFrame)

-- Player avatar (square, MC-style with inset border)
local avatarFrame = Instance.new("Frame")
avatarFrame.Name = "AvatarFrame"
avatarFrame.Size = UDim2.new(0, 42, 0, 42)
avatarFrame.Position = UDim2.new(0, 5, 0.5, -21)
avatarFrame.BackgroundColor3 = MC.PanelDark
avatarFrame.BorderSizePixel = 0
avatarFrame.Parent = headerFrame

addInsetBevel(avatarFrame)

local avatarImage = Instance.new("ImageLabel")
avatarImage.Name = "Avatar"
avatarImage.Size = UDim2.new(1, -6, 1, -6)
avatarImage.Position = UDim2.new(0, 3, 0, 3)
avatarImage.BackgroundTransparency = 1
avatarImage.BorderSizePixel = 0
avatarImage.Image = ""
avatarImage.ScaleType = Enum.ScaleType.Fit
avatarImage.Parent = avatarFrame

-- Player name (with MC shadow text)
local playerNameLabel, playerNameShadow = createShadowedText(headerFrame, {
	Name = "PlayerName",
	Size = UDim2.new(1, -100, 0, 22),
	Position = UDim2.new(0, 55, 0, 6),
	Font = Enum.Font.Arcade,
	TextSize = 16,
	TextColor3 = MC.TextWhite,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "Player Name",
})

-- Status label (friend, access, etc.)
local statusLabel, statusShadow = createShadowedText(headerFrame, {
	Name = "Status",
	Size = UDim2.new(1, -100, 0, 18),
	Position = UDim2.new(0, 55, 0, 28),
	Font = Enum.Font.Arcade,
	TextSize = 12,
	TextColor3 = MC.TextGold,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "",
})

-- Close button (X) - MC-style small raised button
local closeButton = Instance.new("TextButton")
closeButton.Name = "CloseButton"
closeButton.Size = UDim2.new(0, 28, 0, 28)
closeButton.Position = UDim2.new(1, -34, 0.5, -14)
closeButton.BackgroundColor3 = MC.ButtonRed
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.Arcade
closeButton.TextSize = 14
closeButton.TextColor3 = MC.TextWhite
closeButton.Text = ""
closeButton.AutoButtonColor = false
closeButton.ZIndex = 6
closeButton.Parent = headerFrame

addRaisedBevel(closeButton, Color3.fromRGB(220, 100, 100), Color3.fromRGB(120, 30, 30))

-- X text with drop shadow
local closeShadow = Instance.new("TextLabel")
closeShadow.Name = "XShadow"
closeShadow.Size = UDim2.new(1, 0, 1, 0)
closeShadow.Position = UDim2.new(0, 2, 0, 2)
closeShadow.BackgroundTransparency = 1
closeShadow.Font = Enum.Font.Arcade
closeShadow.TextSize = 14
closeShadow.TextColor3 = MC.TextShadow
closeShadow.Text = "X"
closeShadow.ZIndex = 7
closeShadow.Parent = closeButton

local closeText = Instance.new("TextLabel")
closeText.Name = "XLabel"
closeText.Size = UDim2.new(1, 0, 1, 0)
closeText.BackgroundTransparency = 1
closeText.Font = Enum.Font.Arcade
closeText.TextSize = 14
closeText.TextColor3 = MC.TextWhite
closeText.Text = "X"
closeText.ZIndex = 8
closeText.Parent = closeButton

closeButton.MouseEnter:Connect(function()
	closeButton.BackgroundColor3 = MC.ButtonRedHover
end)
closeButton.MouseLeave:Connect(function()
	closeButton.BackgroundColor3 = MC.ButtonRed
end)

-- ============================================
-- BUTTON CONTAINER (below header)
-- ============================================

local buttonContainer = Instance.new("Frame")
buttonContainer.Name = "ButtonContainer"
buttonContainer.Size = UDim2.new(1, -16, 0, 90)
buttonContainer.Position = UDim2.new(0, 8, 0, 68)
buttonContainer.BackgroundTransparency = 1
buttonContainer.Parent = mainFrame

local buttonLayout = Instance.new("UIGridLayout")
buttonLayout.CellSize = UDim2.new(0.5, -5, 0, 36)
buttonLayout.CellPadding = UDim2.new(0, 10, 0, 8)
buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Top
buttonLayout.Parent = buttonContainer

-- ============================================
-- MC-STYLE BUTTON CREATION
-- ============================================

-- Greyed-out disabled colors
local MC_DISABLED_BG = Color3.fromRGB(80, 80, 80)
local MC_DISABLED_TEXT = Color3.fromRGB(110, 110, 110)
local MC_DISABLED_SHADOW = Color3.fromRGB(50, 50, 50)

local function createMCButton(name, text, bgColor, hoverColor)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = UDim2.new(0, 170, 0, 36)
	button.BackgroundColor3 = bgColor
	button.BackgroundTransparency = 0
	button.BorderSizePixel = 0
	button.Font = Enum.Font.Arcade
	button.TextSize = 13
	button.TextColor3 = MC.TextWhite
	button.Text = "" -- We'll use custom text labels
	button.AutoButtonColor = false
	button.Visible = false
	button.Parent = buttonContainer

	-- Raised bevel on button
	local lighter = Color3.new(
		math.min(bgColor.R + 0.15, 1),
		math.min(bgColor.G + 0.15, 1),
		math.min(bgColor.B + 0.15, 1)
	)
	local darker = Color3.new(
		math.max(bgColor.R - 0.2, 0),
		math.max(bgColor.G - 0.2, 0),
		math.max(bgColor.B - 0.2, 0)
	)
	addRaisedBevel(button, lighter, darker)

	-- Shadow text
	local textShadow = Instance.new("TextLabel")
	textShadow.Name = "TextShadow"
	textShadow.Size = UDim2.new(1, 0, 1, 0)
	textShadow.Position = UDim2.new(0, 2, 0, 2)
	textShadow.BackgroundTransparency = 1
	textShadow.Font = Enum.Font.Arcade
	textShadow.TextSize = 13
	textShadow.TextColor3 = MC.TextShadow
	textShadow.Text = text
	textShadow.ZIndex = 6
	textShadow.Parent = button

	-- Main text
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "TextLabel"
	textLabel.Size = UDim2.new(1, 0, 1, 0)
	textLabel.Position = UDim2.new(0, 0, 0, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.Arcade
	textLabel.TextSize = 13
	textLabel.TextColor3 = MC.TextWhite
	textLabel.Text = text
	textLabel.ZIndex = 7
	textLabel.Parent = button

	-- Track disabled state per button
	local isDisabled = false

	-- Hover effects (respect disabled state)
	button.MouseEnter:Connect(function()
		if not isDisabled then
			button.BackgroundColor3 = hoverColor
		end
	end)

	button.MouseLeave:Connect(function()
		if not isDisabled then
			button.BackgroundColor3 = bgColor
		else
			button.BackgroundColor3 = MC_DISABLED_BG
		end
	end)

	-- Store metadata on the button for enable/disable
	button:SetAttribute("_origBgColor_R", bgColor.R)
	button:SetAttribute("_origBgColor_G", bgColor.G)
	button:SetAttribute("_origBgColor_B", bgColor.B)

	-- Disable function: grey out + block clicks
	local btnMeta = {}
	btnMeta.Button = button
	btnMeta.TextLabel = textLabel
	btnMeta.TextShadow = textShadow
	btnMeta.BgColor = bgColor

	btnMeta.SetDisabled = function(disabled)
		isDisabled = disabled
		if disabled then
			button.BackgroundColor3 = MC_DISABLED_BG
			textLabel.TextColor3 = MC_DISABLED_TEXT
			textShadow.TextColor3 = MC_DISABLED_SHADOW
			-- Update bevels to match greyed out
			for _, child in button:GetChildren() do
				if child.Name == "BevelTop" or child.Name == "BevelLeft" then
					child.BackgroundColor3 = Color3.fromRGB(110, 110, 110)
				elseif child.Name == "BevelBottom" or child.Name == "BevelRight" then
					child.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
				end
			end
		else
			button.BackgroundColor3 = bgColor
			textLabel.TextColor3 = MC.TextWhite
			textShadow.TextColor3 = MC.TextShadow
			-- Restore bevels
			for _, child in button:GetChildren() do
				if child.Name == "BevelTop" or child.Name == "BevelLeft" then
					child.BackgroundColor3 = lighter
				elseif child.Name == "BevelBottom" or child.Name == "BevelRight" then
					child.BackgroundColor3 = darker
				end
			end
		end
	end

	btnMeta.IsDisabled = function()
		return isDisabled
	end

	return button, btnMeta
end

-- Create all action buttons
local shareButton, shareMeta = createMCButton("ShareButton", "Share Plot", MC.ButtonGreen, MC.ButtonGreenHover)
local revokeButton, revokeMeta = createMCButton("RevokeButton", "Revoke Access", MC.ButtonOrange, MC.ButtonOrangeHover)
local kickButton, kickMeta = createMCButton("KickButton", "Kick from Plot", MC.ButtonOrange, MC.ButtonOrangeHover)
local blockButton, blockMeta = createMCButton("BlockButton", "Block from Plot", MC.ButtonRed, MC.ButtonRedHover)
local unblockButton, unblockMeta = createMCButton("UnblockButton", "Unblock", MC.ButtonGreen, MC.ButtonGreenHover)

local allButtonMetas = { shareMeta, revokeMeta, kickMeta, blockMeta, unblockMeta }

-- ============================================
-- NOTIFICATION TOAST (MC-style)
-- ============================================

local toastFrame = Instance.new("Frame")
toastFrame.Name = "Toast"
toastFrame.Size = UDim2.new(0, 350, 0, 44)
toastFrame.AnchorPoint = Vector2.new(0.5, 0)
toastFrame.Position = UDim2.new(0.5, 0, 0, -60) -- Start off-screen
toastFrame.BackgroundColor3 = MC.PanelBg
toastFrame.BackgroundTransparency = 0
toastFrame.BorderSizePixel = 0
toastFrame.Visible = false
toastFrame.Parent = screenGui

addRaisedBevel(toastFrame)

-- No stroke on toast - bevels provide the border

local toastLabel, toastShadow = createShadowedText(toastFrame, {
	Name = "Message",
	Size = UDim2.new(1, -16, 1, 0),
	Position = UDim2.new(0, 8, 0, 0),
	Font = Enum.Font.Arcade,
	TextSize = 14,
	TextColor3 = MC.TextWhite,
	TextXAlignment = Enum.TextXAlignment.Center,
	Text = "",
})

local function showToast(message, isSuccess)
	toastLabel.Text = message
	toastShadow.Text = message
	toastLabel.TextColor3 = isSuccess and MC.TextGreen or MC.TextRed
	toastFrame.Visible = true

	-- Animate in from top
	toastFrame.Position = UDim2.new(0.5, 0, 0, -60)
	TweenService:Create(toastFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, 50)
	}):Play()

	-- Auto-hide after 3 seconds
	task.delay(3, function()
		TweenService:Create(toastFrame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 0, -60)
		}):Play()
		task.wait(0.3)
		toastFrame.Visible = false
	end)
end

-- ============================================
-- UI ANIMATION
-- ============================================

local function openUI()
	if isUIOpen then return end
	isUIOpen = true

	mainFrame.Visible = true
	-- Animate up from below into position above hotbar
	mainFrame.Position = UDim2.new(0.5, 0, 1, targetY + panelHeight + 20)

	TweenService:Create(mainFrame, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 1, targetY)
	}):Play()
end

local function closeUI()
	if not isUIOpen then return end
	isUIOpen = false
	currentTargetPlayer = nil

	TweenService:Create(mainFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = UDim2.new(0.5, 0, 1, targetY + panelHeight + 20)
	}):Play()

	task.wait(0.2)
	mainFrame.Visible = false
end

-- ============================================
-- PLAYER DETECTION
-- ============================================

local function getPlayerFromCharacter(character)
	if not character then return nil end
	return Players:GetPlayerFromCharacter(character)
end

local function raycastForPlayer(screenPosition)
	local ray = camera:ScreenPointToRay(screenPosition.X, screenPosition.Y)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {player.Character}

	local result = workspace:Raycast(ray.Origin, ray.Direction * MAX_INTERACTION_DISTANCE, raycastParams)

	if result and result.Instance then
		local character = result.Instance:FindFirstAncestorOfClass("Model")
		if character then
			local targetPlayer = getPlayerFromCharacter(character)
			if targetPlayer and targetPlayer ~= player then
				return targetPlayer
			end
		end
	end

	return nil
end

local function findPlayerAtScreenPosition(screenPosition)
	local closestPlayer = nil
	local closestDistance = math.huge

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= player and otherPlayer.Character then
			local hrp = otherPlayer.Character:FindFirstChild("HumanoidRootPart")
			if hrp then
				local myHRP = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				if myHRP then
					local distance = (hrp.Position - myHRP.Position).Magnitude
					if distance <= MAX_INTERACTION_DISTANCE then
						local screenPos, onScreen = camera:WorldToScreenPoint(hrp.Position)
						if onScreen then
							local screenDist = (Vector2.new(screenPos.X, screenPos.Y) - Vector2.new(screenPosition.X, screenPosition.Y)).Magnitude
							if screenDist < 100 and screenDist < closestDistance then
								closestDistance = screenDist
								closestPlayer = otherPlayer
							end
						end
					end
				end
			end
		end
	end

	return closestPlayer
end

-- ============================================
-- UPDATE UI WITH PLAYER INFO
-- ============================================

local function updateUIForPlayer(targetPlayer)
	if not targetPlayer then return end

	currentTargetPlayer = targetPlayer

	-- Set avatar
	local success, thumbContent = pcall(function()
		return Players:GetUserThumbnailAsync(targetPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
	end)
	if success then
		avatarImage.Image = thumbContent
	else
		avatarImage.Image = ""
	end

	-- Set name
	local displayText
	if targetPlayer.DisplayName ~= targetPlayer.Name then
		displayText = targetPlayer.DisplayName
	else
		displayText = targetPlayer.DisplayName
	end
	playerNameLabel.Text = displayText
	playerNameShadow.Text = displayText

	-- Get info from server
	local info = GetPlayerInteractionInfo:InvokeServer(targetPlayer.UserId)

	if not info then
		statusLabel.Text = "Could not load info"
		statusShadow.Text = "Could not load info"
		shareButton.Visible = false
		revokeButton.Visible = false
		kickButton.Visible = false
		blockButton.Visible = false
		unblockButton.Visible = false
		return
	end

	-- Build status text
	local statusParts = {}
	if info.isFriend then
		table.insert(statusParts, "Friend")
	end
	if info.isShared then
		table.insert(statusParts, "Has Access")
	end
	if info.isBlocked then
		table.insert(statusParts, "Blocked")
	end
	if info.isBlockedByTarget then
		table.insert(statusParts, "Blocked You")
	end
	if info.isOnYourPlot then
		table.insert(statusParts, "On Your Plot")
	end

	local statusText = ""
	if #statusParts > 0 then
		statusText = table.concat(statusParts, " | ")
	end
	statusLabel.Text = statusText
	statusShadow.Text = statusText

	-- Adjust status color based on context
	if info.isBlockedByTarget then
		statusLabel.TextColor3 = MC.TextRed
	elseif info.isBlocked then
		statusLabel.TextColor3 = MC.TextRed
	elseif info.isFriend then
		statusLabel.TextColor3 = MC.TextGold
	else
		statusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	end

	-- Show/hide buttons based on state
	shareButton.Visible = info.isFriend and not info.isShared and not info.isBlocked
	revokeButton.Visible = info.isShared
	kickButton.Visible = info.isOnYourPlot and info.requestingPlayerOnOwnPlot
	blockButton.Visible = not info.isBlocked
	unblockButton.Visible = info.isBlocked

	-- Grey out all buttons if the target has blocked US
	local disableAll = info.isBlockedByTarget == true
	for _, meta in ipairs(allButtonMetas) do
		meta.SetDisabled(disableAll)
	end

	-- Dynamically resize panel based on visible button count
	local visibleCount = 0
	if shareButton.Visible then visibleCount += 1 end
	if revokeButton.Visible then visibleCount += 1 end
	if kickButton.Visible then visibleCount += 1 end
	if blockButton.Visible then visibleCount += 1 end
	if unblockButton.Visible then visibleCount += 1 end

	local rows = math.ceil(visibleCount / 2)
	local buttonAreaHeight = rows * 36 + (rows - 1) * 8
	local newPanelHeight = 68 + buttonAreaHeight + 16 -- header + buttons + padding

	buttonContainer.Size = UDim2.new(1, -16, 0, buttonAreaHeight)
	mainFrame.Size = UDim2.new(0, panelWidth, 0, newPanelHeight)
end

-- ============================================
-- BUTTON HANDLERS
-- ============================================

shareButton.MouseButton1Click:Connect(function()
	if not currentTargetPlayer or shareMeta.IsDisabled() then return end
	SharePlotAccess:FireServer(currentTargetPlayer.UserId)
end)

revokeButton.MouseButton1Click:Connect(function()
	if not currentTargetPlayer or revokeMeta.IsDisabled() then return end
	RevokePlotAccess:FireServer(currentTargetPlayer.UserId)
end)

kickButton.MouseButton1Click:Connect(function()
	if not currentTargetPlayer or kickMeta.IsDisabled() then return end
	KickFromPlot:FireServer(currentTargetPlayer.UserId)
end)

blockButton.MouseButton1Click:Connect(function()
	if not currentTargetPlayer or blockMeta.IsDisabled() then return end
	BlockFromPlot:FireServer(currentTargetPlayer.UserId)
end)

unblockButton.MouseButton1Click:Connect(function()
	if not currentTargetPlayer or unblockMeta.IsDisabled() then return end
	UnblockFromPlot:FireServer(currentTargetPlayer.UserId)
end)

closeButton.MouseButton1Click:Connect(function()
	closeUI()
end)

-- ============================================
-- SERVER RESULT HANDLER
-- ============================================

PlotPermissionResult.OnClientEvent:Connect(function(action, success, message)
	showToast(message, success)

	-- Refresh UI if action succeeded
	if success and currentTargetPlayer and isUIOpen then
		task.wait(0.2)
		updateUIForPlayer(currentTargetPlayer)
	end
end)

-- ============================================
-- INPUT HANDLING
-- ============================================

-- Right-click handler (desktop)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- Right mouse button (desktop) - check gameProcessed for mouse only
	if input.UserInputType == Enum.UserInputType.MouseButton2 and not gameProcessed then
		local mousePos = UserInputService:GetMouseLocation()

		local targetPlayer = raycastForPlayer(mousePos)
		if not targetPlayer then
			targetPlayer = findPlayerAtScreenPosition(mousePos)
		end

		if targetPlayer then
			updateUIForPlayer(targetPlayer)
			openUI()
		end
	end

	-- Touch input for mobile - DON'T check gameProcessed
	-- (mobile touches are almost always consumed by camera/game)
	if input.UserInputType == Enum.UserInputType.Touch then
		longPressStartTime = tick()
		longPressTarget = input.Position
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if input.UserInputType == Enum.UserInputType.Touch then
		-- On mobile: if released quickly (tap), check if it was on a player
		if longPressStartTime then
			local holdTime = tick() - longPressStartTime
			-- Quick tap (under long press threshold) - check for player under tap
			if holdTime < LONG_PRESS_TIME and longPressTarget then
				local targetPlayer = raycastForPlayer(longPressTarget)
				if not targetPlayer then
					targetPlayer = findPlayerAtScreenPosition(longPressTarget)
				end

				if targetPlayer then
					updateUIForPlayer(targetPlayer)
					openUI()
				end
			end
		end
		longPressStartTime = nil
		longPressTarget = nil
	end
end)

-- Long press detection for mobile (backup - triggers after holding)
RunService.Heartbeat:Connect(function()
	if longPressStartTime and longPressTarget then
		if tick() - longPressStartTime >= LONG_PRESS_TIME then
			local targetPlayer = raycastForPlayer(longPressTarget)
			if not targetPlayer then
				targetPlayer = findPlayerAtScreenPosition(longPressTarget)
			end

			if targetPlayer then
				updateUIForPlayer(targetPlayer)
				openUI()
			end

			longPressStartTime = nil
			longPressTarget = nil
		end
	end
end)

-- Close UI with ESC, E, or clicking outside
local GuiService = game:GetService("GuiService")

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not isUIOpen then return end

	-- ESC or E to close
	if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.E then
		closeUI()
		return
	end

	-- Don't close when clicking on UI elements (buttons, etc.)
	if gameProcessed then return end

	-- Click outside to close
	if input.UserInputType == Enum.UserInputType.MouseButton1 or
		input.UserInputType == Enum.UserInputType.Touch then
		-- Account for GUI inset since ScreenGui uses IgnoreGuiInset = true
		local inset = GuiService:GetGuiInset()
		local mousePos = UserInputService:GetMouseLocation()
		local adjustedY = mousePos.Y + inset.Y
		local framePos = mainFrame.AbsolutePosition
		local frameSize = mainFrame.AbsoluteSize

		if mousePos.X < framePos.X or mousePos.X > framePos.X + frameSize.X or
			adjustedY < framePos.Y or adjustedY > framePos.Y + frameSize.Y then
			closeUI()
		end
	end
end)

-- ============================================
-- EXPOSE FOR OTHER SCRIPTS
-- ============================================

_G.PlayerInteractionUI = {
	IsOpen = function() return isUIOpen end,
	Close = closeUI,
}

print("[PlayerInteractionUI] Minecraft-style loaded")
