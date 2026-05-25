--[[
	BiomeSelectionUI (Client)
	Premium Plot Setup with biome, terrain, weather, and season controls
	Minecraft stone-style UI matching TitleScreen/SaveLoadUI aesthetic
	
	GAMEPASS SYSTEM:
	- Free: Any biome, Flat terrain only
	- Premium: Natural terrain, Weather, Seasons
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local OpenBiomeUI = Remotes:WaitForChild("OpenBiomeUI", 10)
local SelectBiome = Remotes:WaitForChild("SelectBiome", 10)

local ApplyBiomeColors = Remotes:FindFirstChild("ApplyBiomeColors")
if not ApplyBiomeColors then
	ApplyBiomeColors = Instance.new("RemoteEvent")
	ApplyBiomeColors.Name = "ApplyBiomeColors"
	ApplyBiomeColors.Parent = Remotes
end

-- ============================================
-- DEVICE DETECTION
-- ============================================
local IsMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local function isMobile()
	return IsMobile
end

-- ============================================
-- MINECRAFT STYLE CONSTANTS
-- ============================================
local BORDER_SIZE = 3
local FONT = Enum.Font.Arcade

local MC = {
	-- Panel
	panelBg = Color3.fromRGB(60, 60, 60),
	panelHighlight = Color3.fromRGB(100, 100, 100),
	panelShadow = Color3.fromRGB(30, 30, 30),
	
	-- Inner containers
	innerBg = Color3.fromRGB(20, 20, 20),
	innerHighlight = Color3.fromRGB(50, 50, 50),
	innerShadow = Color3.fromRGB(10, 10, 10),
	
	-- Buttons
	btnNormal = Color3.fromRGB(110, 110, 110),
	btnHover = Color3.fromRGB(130, 130, 130),
	btnHighlight = Color3.fromRGB(160, 160, 160),
	btnShadow = Color3.fromRGB(55, 55, 55),
	
	-- Green accent
	greenNormal = Color3.fromRGB(60, 130, 60),
	greenHover = Color3.fromRGB(80, 150, 80),
	greenHighlight = Color3.fromRGB(100, 190, 100),
	greenShadow = Color3.fromRGB(30, 70, 30),
	
	-- Red/danger
	redNormal = Color3.fromRGB(140, 50, 50),
	redHover = Color3.fromRGB(160, 60, 60),
	redHighlight = Color3.fromRGB(190, 80, 80),
	redShadow = Color3.fromRGB(70, 25, 25),
	
	-- Yellow/warning
	yellowNormal = Color3.fromRGB(180, 150, 40),
	yellowHover = Color3.fromRGB(200, 170, 60),
	yellowHighlight = Color3.fromRGB(230, 200, 80),
	yellowShadow = Color3.fromRGB(100, 80, 20),
	
	-- Close
	closeNormal = Color3.fromRGB(90, 90, 90),
	closeHover = Color3.fromRGB(110, 110, 110),
	closeHighlight = Color3.fromRGB(140, 140, 140),
	closeShadow = Color3.fromRGB(45, 45, 45),
	
	-- Text
	text = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(180, 180, 180),
	textShadow = Color3.fromRGB(20, 20, 20),
	textWarning = Color3.fromRGB(255, 193, 7),
	
	-- Selected state (green-tinted)
	selectedBg = Color3.fromRGB(50, 80, 50),
	selectedHighlight = Color3.fromRGB(80, 140, 80),
	selectedShadow = Color3.fromRGB(25, 45, 25),
}

-- Keep biome colors for the cards
local BiomeColors = {
	Flat = Color3.fromRGB(120, 100, 80),
	Plains = Color3.fromRGB(100, 180, 80),
	Forest = Color3.fromRGB(50, 120, 50),
	BirchForest = Color3.fromRGB(140, 180, 100),
	Taiga = Color3.fromRGB(70, 100, 90),
	Desert = Color3.fromRGB(210, 180, 100),
	Swamp = Color3.fromRGB(80, 100, 70),
	Mountains = Color3.fromRGB(120, 120, 130),
	Snowy = Color3.fromRGB(200, 220, 240),
}

local WeatherOptions = {
	{id = "Clear", name = "Clear"},
	{id = "Rain", name = "Rain"},
	{id = "Snow", name = "Snow"},
	{id = "Fog", name = "Fog"},
	{id = "Storm", name = "Storm"},
}

local SeasonOptions = {
	{id = "Spring", name = "Spring"},
	{id = "Summer", name = "Summer"},
	{id = "Autumn", name = "Autumn"},
	{id = "Winter", name = "Winter"},
}

-- ============================================
-- GAMEPASS CONFIGURATION
-- ============================================
local PREMIUM_GAMEPASS_ID = 1676832631
local OWNER_USER_ID = game.CreatorId
local hasPremium = false

local function checkPremiumOwnership()
	if player.UserId == OWNER_USER_ID then return true end
	if BetaConfig.IS_BETA then return true end
	if PREMIUM_GAMEPASS_ID == 0 then return false end
	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, PREMIUM_GAMEPASS_ID)
	end)
	if success then return owns end
	warn("[BiomeSelectionUI] Failed to check gamepass ownership")
	return false
end

hasPremium = checkPremiumOwnership()
print("[BiomeSelectionUI] Premium status: " .. tostring(hasPremium))

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamePassId, wasPurchased)
	if gamePassId == PREMIUM_GAMEPASS_ID and wasPurchased then
		hasPremium = true
		print("[BiomeSelectionUI] Premium purchased! Unlocking features...")
	end
end)

-- ============================================
-- STATE
-- ============================================
local currentPlot = nil
local currentBiome = nil
local selectedBiome = nil
local hasExistingBlocks = false
local pendingBiome = nil
local selectedTerrainStyle = "Flat"
local initialTerrainStyle = nil
local selectedWeather = "Clear"
local selectedSeason = "Summer"
local currentSeed = math.random(1, 999999)
local isUIOpen = false
local preferredBiomes = {}
local biomeBlur = nil

_G.BiomeUI = {
	IsOpen = function()
		return isUIOpen
	end
}

RunService.RenderStepped:Connect(function()
	if isUIOpen then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end)

-- ============================================
-- MINECRAFT BORDER HELPER
-- ============================================
local function addMinecraftBorder(parent, highlightColor, shadowColor, thickness)
	local bs = thickness or BORDER_SIZE
	local top = Instance.new("Frame")
	top.Name = "BorderTop"
	top.Size = UDim2.new(1, 0, 0, bs)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = highlightColor
	top.BorderSizePixel = 0
	top.ZIndex = parent.ZIndex + 1
	top.Parent = parent
	local left = Instance.new("Frame")
	left.Name = "BorderLeft"
	left.Size = UDim2.new(0, bs, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = highlightColor
	left.BorderSizePixel = 0
	left.ZIndex = parent.ZIndex + 1
	left.Parent = parent
	local bottom = Instance.new("Frame")
	bottom.Name = "BorderBottom"
	bottom.Size = UDim2.new(1, 0, 0, bs)
	bottom.Position = UDim2.new(0, 0, 1, -bs)
	bottom.BackgroundColor3 = shadowColor
	bottom.BorderSizePixel = 0
	bottom.ZIndex = parent.ZIndex + 1
	bottom.Parent = parent
	local right = Instance.new("Frame")
	right.Name = "BorderRight"
	right.Size = UDim2.new(0, bs, 1, 0)
	right.Position = UDim2.new(1, -bs, 0, 0)
	right.BackgroundColor3 = shadowColor
	right.BorderSizePixel = 0
	right.ZIndex = parent.ZIndex + 1
	right.Parent = parent
	return {top = top, left = left, bottom = bottom, right = right}
end

-- Text shadow helper
local function addTextShadow(parent, text, textSize, font, offsetX, offsetY)
	offsetX = offsetX or 2
	offsetY = offsetY or 2
	local textColor = parent.TextColor3
	local xAlign = parent.TextXAlignment
	local yAlign = parent.TextYAlignment
	local truncate = parent.TextTruncate
	local wrapped = parent.TextWrapped
	local useFont = font or FONT
	parent.TextTransparency = 1
	local shadow = Instance.new("TextLabel")
	shadow.Name = "TextShadow"
	shadow.Size = UDim2.new(1, 0, 1, 0)
	shadow.Position = UDim2.new(0, offsetX, 0, offsetY)
	shadow.BackgroundTransparency = 1
	shadow.Text = text
	shadow.TextColor3 = MC.textShadow
	shadow.TextSize = textSize
	shadow.Font = useFont
	shadow.TextXAlignment = xAlign
	shadow.TextYAlignment = yAlign
	shadow.TextTruncate = truncate
	shadow.TextWrapped = wrapped
	shadow.ZIndex = parent.ZIndex + 1
	shadow.Parent = parent
	local foreground = Instance.new("TextLabel")
	foreground.Name = "TextForeground"
	foreground.Size = UDim2.new(1, 0, 1, 0)
	foreground.BackgroundTransparency = 1
	foreground.Text = text
	foreground.TextColor3 = textColor
	foreground.TextSize = textSize
	foreground.Font = useFont
	foreground.TextXAlignment = xAlign
	foreground.TextYAlignment = yAlign
	foreground.TextTruncate = truncate
	foreground.TextWrapped = wrapped
	foreground.ZIndex = parent.ZIndex + 2
	foreground.Parent = parent
	return shadow, foreground
end

-- Update text shadow content
local function updateShadowText(parent, newText)
	local fg = parent:FindFirstChild("TextForeground")
	local sh = parent:FindFirstChild("TextShadow")
	if fg then fg.Text = newText end
	if sh then sh.Text = newText end
end

-- ============================================
-- CREATE MC-STYLE BUTTON
-- ============================================
local function createMCButton(name, text, parent, size, colorSet, layoutOrder)
	colorSet = colorSet or {
		normal = MC.btnNormal, hover = MC.btnHover,
		highlight = MC.btnHighlight, shadow = MC.btnShadow,
	}
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.BackgroundColor3 = colorSet.normal
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	if layoutOrder then button.LayoutOrder = layoutOrder end
	button.Parent = parent
	local borders = addMinecraftBorder(button, colorSet.highlight, colorSet.shadow)
	local fg = Instance.new("TextLabel")
	fg.Name = "TextForeground"
	fg.Size = UDim2.new(1, 0, 1, 0)
	fg.BackgroundTransparency = 1
	fg.Text = text
	fg.TextColor3 = MC.text
	fg.TextSize = IsMobile and 11 or 13
	fg.Font = FONT
	fg.ZIndex = button.ZIndex + 2
	fg.Parent = button
	local sh = Instance.new("TextLabel")
	sh.Name = "TextShadow"
	sh.Size = UDim2.new(1, 0, 1, 0)
	sh.Position = UDim2.new(0, 2, 0, 2)
	sh.BackgroundTransparency = 1
	sh.Text = text
	sh.TextColor3 = MC.textShadow
	sh.TextSize = IsMobile and 11 or 13
	sh.Font = FONT
	sh.ZIndex = button.ZIndex + 1
	sh.Parent = button
	button.MouseEnter:Connect(function()
		if button:GetAttribute("Disabled") then return end
		button.BackgroundColor3 = colorSet.hover
	end)
	button.MouseLeave:Connect(function()
		if button:GetAttribute("Disabled") then return end
		button.BackgroundColor3 = colorSet.normal
		borders.top.BackgroundColor3 = colorSet.highlight
		borders.left.BackgroundColor3 = colorSet.highlight
		borders.bottom.BackgroundColor3 = colorSet.shadow
		borders.right.BackgroundColor3 = colorSet.shadow
	end)
	button.MouseButton1Down:Connect(function()
		if button:GetAttribute("Disabled") then return end
		borders.top.BackgroundColor3 = colorSet.shadow
		borders.left.BackgroundColor3 = colorSet.shadow
		borders.bottom.BackgroundColor3 = colorSet.highlight
		borders.right.BackgroundColor3 = colorSet.highlight
	end)
	button.MouseButton1Up:Connect(function()
		if button:GetAttribute("Disabled") then return end
		borders.top.BackgroundColor3 = colorSet.highlight
		borders.left.BackgroundColor3 = colorSet.highlight
		borders.bottom.BackgroundColor3 = colorSet.shadow
		borders.right.BackgroundColor3 = colorSet.shadow
	end)
	return button, borders, fg, sh
end

local function setMCButtonText(button, text)
	local fg = button:FindFirstChild("TextForeground")
	local sh = button:FindFirstChild("TextShadow")
	if fg then fg.Text = text end
	if sh then sh.Text = text end
end

-- ============================================
-- CREATE UI
-- ============================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "BiomeSelectionUI"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 100
screenGui.Parent = playerGui

local function openUI()
	isUIOpen = true
	screenGui.Enabled = true
	local crosshairGui = playerGui:FindFirstChild("CrosshairGui")
	if crosshairGui then crosshairGui.Enabled = false end
	-- Add blur
	if biomeBlur then biomeBlur:Destroy() end
	biomeBlur = Instance.new("BlurEffect")
	biomeBlur.Name = "BiomeBlur"
	biomeBlur.Size = 0
	biomeBlur.Parent = Lighting
	TweenService:Create(biomeBlur, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = 20
	}):Play()
	task.defer(function()
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end)
end

local function closeUI()
	isUIOpen = false
	screenGui.Enabled = false
	local crosshairGui = playerGui:FindFirstChild("CrosshairGui")
	if crosshairGui then crosshairGui.Enabled = true end
	-- Remove blur
	if biomeBlur then
		TweenService:Create(biomeBlur, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = 0
		}):Play()
		task.delay(0.3, function()
			if biomeBlur then biomeBlur:Destroy(); biomeBlur = nil end
		end)
	end
end

-- Transparent click-catcher overlay (blur handles dimming)
local overlay = Instance.new("Frame")
overlay.Name = "Overlay"
overlay.Size = UDim2.new(1, 0, 1, 0)
overlay.BackgroundTransparency = 1
overlay.BorderSizePixel = 0
overlay.Parent = screenGui

-- Main panel - centered, not fullscreen
local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
mainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
if IsMobile then
	mainFrame.Size = UDim2.new(0.95, 0, 0.85, 0)
else
	mainFrame.Size = UDim2.new(0, 720, 0, 520)
end
mainFrame.BackgroundColor3 = MC.panelBg
mainFrame.BorderSizePixel = 0
mainFrame.ClipsDescendants = true
mainFrame.Parent = screenGui

if IsMobile then
	local sc = Instance.new("UISizeConstraint")
	sc.MaxSize = Vector2.new(750, 560)
	sc.Parent = mainFrame
end

addMinecraftBorder(mainFrame, MC.panelHighlight, MC.panelShadow)

-- ===== TITLE BAR =====
local titleBar = Instance.new("Frame")
titleBar.Name = "TitleBar"
titleBar.Size = UDim2.new(1, -6, 0, 36)
titleBar.Position = UDim2.new(0, 3, 0, 3)
titleBar.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame
addMinecraftBorder(titleBar, MC.innerHighlight, MC.innerShadow, 2)

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -50, 1, 0)
title.Position = UDim2.new(0, 12, 0, 0)
title.BackgroundTransparency = 1
title.Text = "Plot Setup"
title.TextColor3 = MC.text
title.TextSize = IsMobile and 14 or 16
title.Font = FONT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar
addTextShadow(title, title.Text, title.TextSize, FONT)

-- Close X button
local closeBtn = createMCButton("CloseBtn", "X", titleBar,
	UDim2.new(0, 28, 0, 28), {
		normal = MC.redNormal, hover = MC.redHover,
		highlight = MC.redHighlight, shadow = MC.redShadow,
	})
closeBtn.Position = UDim2.new(1, -32, 0.5, -14)

-- ===== SCROLLING CONTENT =====
local scrollWrapper = Instance.new("Frame")
scrollWrapper.Name = "ScrollWrapper"
scrollWrapper.Size = UDim2.new(1, -12, 1, -48)
scrollWrapper.Position = UDim2.new(0, 6, 0, 42)
scrollWrapper.BackgroundColor3 = MC.innerBg
scrollWrapper.BorderSizePixel = 0
scrollWrapper.Parent = mainFrame
addMinecraftBorder(scrollWrapper, MC.innerHighlight, MC.innerShadow, 2)

local contentScroll = Instance.new("ScrollingFrame")
contentScroll.Name = "ContentScroll"
contentScroll.Size = UDim2.new(1, -4, 1, -4)
contentScroll.Position = UDim2.new(0, 2, 0, 2)
contentScroll.BackgroundTransparency = 1
contentScroll.BorderSizePixel = 0
contentScroll.ScrollBarThickness = 5
contentScroll.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 85)
contentScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
contentScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
contentScroll.ScrollingDirection = Enum.ScrollingDirection.Y
contentScroll.Parent = scrollWrapper

local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, -12, 0, 0)
content.Position = UDim2.new(0, 6, 0, 0)
content.BackgroundTransparency = 1
content.AutomaticSize = Enum.AutomaticSize.Y
content.Parent = contentScroll

local contentLayout = Instance.new("UIListLayout")
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Padding = UDim.new(0, 10)
contentLayout.Parent = content

local contentPad = Instance.new("UIPadding")
contentPad.PaddingTop = UDim.new(0, 8)
contentPad.PaddingBottom = UDim.new(0, 8)
contentPad.Parent = content

-- ============================================
-- ROW 1: Terrain Style (Full Width)
-- ============================================
local terrainSection = Instance.new("Frame")
terrainSection.Name = "TerrainSection"
terrainSection.Size = UDim2.new(1, 0, 0, 62)
terrainSection.BackgroundTransparency = 1
terrainSection.LayoutOrder = 1
terrainSection.Parent = content

local terrainLabel = Instance.new("TextLabel")
terrainLabel.Size = UDim2.new(1, 0, 0, 18)
terrainLabel.BackgroundTransparency = 1
terrainLabel.Text = "Terrain Style"
terrainLabel.TextColor3 = MC.textDim
terrainLabel.TextSize = IsMobile and 10 or 12
terrainLabel.Font = FONT
terrainLabel.TextXAlignment = Enum.TextXAlignment.Left
terrainLabel.Parent = terrainSection
addTextShadow(terrainLabel, terrainLabel.Text, terrainLabel.TextSize, FONT, 1, 1)

-- Segmented terrain buttons
local segContainer = Instance.new("Frame")
segContainer.Name = "TerrainButtons"
segContainer.Size = UDim2.new(1, 0, 0, 36)
segContainer.Position = UDim2.new(0, 0, 0, 22)
segContainer.BackgroundColor3 = MC.innerBg
segContainer.BorderSizePixel = 0
segContainer.Parent = terrainSection
addMinecraftBorder(segContainer, MC.innerShadow, MC.innerHighlight, 2)

-- Selection indicator
local selectionIndicator = Instance.new("Frame")
selectionIndicator.Name = "Indicator"
selectionIndicator.Size = UDim2.new(1/3, -4, 1, -4)
selectionIndicator.Position = UDim2.new(0, 2, 0, 2)
selectionIndicator.BackgroundColor3 = MC.greenNormal
selectionIndicator.BorderSizePixel = 0
selectionIndicator.ZIndex = 1
selectionIndicator.Parent = segContainer
addMinecraftBorder(selectionIndicator, MC.greenHighlight, MC.greenShadow, 2)

local flatBtn = Instance.new("TextButton")
flatBtn.Size = UDim2.new(1/3, 0, 1, 0)
flatBtn.BackgroundTransparency = 1
flatBtn.Text = "Flat"
flatBtn.TextColor3 = MC.text
flatBtn.TextSize = IsMobile and 11 or 13
flatBtn.Font = FONT
flatBtn.ZIndex = 3
flatBtn.Parent = segContainer

local defaultBtn = Instance.new("TextButton")
defaultBtn.Size = UDim2.new(1/3, 0, 1, 0)
defaultBtn.Position = UDim2.new(1/3, 0, 0, 0)
defaultBtn.BackgroundTransparency = 1
defaultBtn.Text = hasPremium and "Single Biome" or "Single Biome (Locked)"
defaultBtn.TextColor3 = MC.textDim
defaultBtn.TextSize = IsMobile and 11 or 13
defaultBtn.Font = FONT
defaultBtn.ZIndex = 3
defaultBtn.Parent = segContainer

local naturalBtn = Instance.new("TextButton")
naturalBtn.Size = UDim2.new(1/3, 0, 1, 0)
naturalBtn.Position = UDim2.new(2/3, 0, 0, 0)
naturalBtn.BackgroundTransparency = 1
naturalBtn.Text = hasPremium and "Natural" or "Natural (Locked)"
naturalBtn.TextColor3 = MC.textDim
naturalBtn.TextSize = IsMobile and 11 or 13
naturalBtn.Font = FONT
naturalBtn.ZIndex = 3
naturalBtn.Parent = segContainer

-- Forward declares
local regenerateSection, regenerateBtn
local updateBiomeMode

local function updateTerrainSelection()
	local indicatorBorders = {
		selectionIndicator:FindFirstChild("BorderTop"),
		selectionIndicator:FindFirstChild("BorderLeft"),
		selectionIndicator:FindFirstChild("BorderBottom"),
		selectionIndicator:FindFirstChild("BorderRight"),
	}
	if selectedTerrainStyle == "Flat" then
		TweenService:Create(selectionIndicator, TweenInfo.new(0.2, Enum.EasingStyle.Quart), {
			Position = UDim2.new(0, 2, 0, 2)
		}):Play()
		flatBtn.TextColor3 = MC.text
		defaultBtn.TextColor3 = MC.textDim
		naturalBtn.TextColor3 = MC.textDim
	elseif selectedTerrainStyle == "Natural" then
		-- Middle button: Single Biome
		TweenService:Create(selectionIndicator, TweenInfo.new(0.2, Enum.EasingStyle.Quart), {
			Position = UDim2.new(1/3, 2, 0, 2)
		}):Play()
		flatBtn.TextColor3 = MC.textDim
		defaultBtn.TextColor3 = MC.text
		naturalBtn.TextColor3 = MC.textDim
	elseif selectedTerrainStyle == "Default" then
		-- Right button: Natural (random world gen)
		TweenService:Create(selectionIndicator, TweenInfo.new(0.2, Enum.EasingStyle.Quart), {
			Position = UDim2.new(2/3, 2, 0, 2)
		}):Play()
		flatBtn.TextColor3 = MC.textDim
		defaultBtn.TextColor3 = MC.textDim
		naturalBtn.TextColor3 = MC.text
	end
	if updateBiomeMode then updateBiomeMode() end
	if regenerateBtn then
		local terrainChanged = initialTerrainStyle ~= nil and selectedTerrainStyle ~= initialTerrainStyle
		setMCButtonText(regenerateBtn, terrainChanged and "Regenerate Terrain" or "Reset Plot")
	end
end

flatBtn.MouseButton1Click:Connect(function()
	selectedTerrainStyle = "Flat"
	updateTerrainSelection()
end)

defaultBtn.MouseButton1Click:Connect(function()
	if hasPremium then
		selectedTerrainStyle = "Natural" -- Single Biome: natural terrain for one biome
		updateTerrainSelection()
	else
		if PREMIUM_GAMEPASS_ID > 0 then
			MarketplaceService:PromptGamePassPurchase(player, PREMIUM_GAMEPASS_ID)
		end
	end
end)

naturalBtn.MouseButton1Click:Connect(function()
	if hasPremium then
		selectedTerrainStyle = "Default" -- Natural: random multi-biome world gen
		updateTerrainSelection()
	else
		if PREMIUM_GAMEPASS_ID > 0 then
			MarketplaceService:PromptGamePassPurchase(player, PREMIUM_GAMEPASS_ID)
		end
	end
end)

-- ============================================
-- ROW 2: Two Columns
-- ============================================
local columnsRow = Instance.new("Frame")
columnsRow.Name = "ColumnsRow"
columnsRow.Size = UDim2.new(1, 0, 0, 0)
columnsRow.BackgroundTransparency = 1
columnsRow.AutomaticSize = Enum.AutomaticSize.Y
columnsRow.LayoutOrder = 2
columnsRow.Parent = content

-- Left Column (Biomes)
local leftColumn = Instance.new("Frame")
leftColumn.Name = "LeftColumn"
leftColumn.Size = UDim2.new(0.5, -5, 0, 0)
leftColumn.BackgroundTransparency = 1
leftColumn.AutomaticSize = Enum.AutomaticSize.Y
leftColumn.Parent = columnsRow

local leftLayout = Instance.new("UIListLayout")
leftLayout.SortOrder = Enum.SortOrder.LayoutOrder
leftLayout.Padding = UDim.new(0, 6)
leftLayout.Parent = leftColumn

-- Right Column (Environment)
local rightColumn = Instance.new("Frame")
rightColumn.Name = "RightColumn"
rightColumn.Size = UDim2.new(0.5, -5, 0, 0)
rightColumn.Position = UDim2.new(0.5, 5, 0, 0)
rightColumn.BackgroundTransparency = 1
rightColumn.AutomaticSize = Enum.AutomaticSize.Y
rightColumn.Parent = columnsRow

local rightLayout = Instance.new("UIListLayout")
rightLayout.SortOrder = Enum.SortOrder.LayoutOrder
rightLayout.Padding = UDim.new(0, 6)
rightLayout.Parent = rightColumn

-- ============================================
-- LEFT: Biome Section
-- ============================================
local biomeLabel = Instance.new("TextLabel")
biomeLabel.Size = UDim2.new(1, 0, 0, 16)
biomeLabel.BackgroundTransparency = 1
biomeLabel.Text = "Biome (click to apply colors)"
biomeLabel.TextColor3 = MC.textDim
biomeLabel.TextSize = IsMobile and 10 or 11
biomeLabel.Font = FONT
biomeLabel.TextXAlignment = Enum.TextXAlignment.Left
biomeLabel.LayoutOrder = 1
biomeLabel.Parent = leftColumn
addTextShadow(biomeLabel, biomeLabel.Text, biomeLabel.TextSize, FONT, 1, 1)

local biomeHint = Instance.new("TextLabel")
biomeHint.Size = UDim2.new(1, 0, 0, 12)
biomeHint.BackgroundTransparency = 1
biomeHint.Text = "Toggle biomes to include (or leave empty for random)"
biomeHint.TextColor3 = Color3.fromRGB(130, 130, 130)
biomeHint.TextSize = IsMobile and 8 or 9
biomeHint.Font = FONT
biomeHint.TextXAlignment = Enum.TextXAlignment.Left
biomeHint.TextWrapped = true
biomeHint.LayoutOrder = 1
biomeHint.Visible = false
biomeHint.Parent = leftColumn

local biomeContainer = Instance.new("Frame")
biomeContainer.Name = "BiomeContainer"
biomeContainer.Size = UDim2.new(1, 0, 0, 0)
biomeContainer.BackgroundTransparency = 1
biomeContainer.AutomaticSize = Enum.AutomaticSize.Y
biomeContainer.LayoutOrder = 2
biomeContainer.Parent = leftColumn

local biomeGrid = Instance.new("UIGridLayout")
biomeGrid.CellSize = UDim2.new(0.5, -3, 0, 62)
biomeGrid.CellPadding = UDim2.new(0, 6, 0, 6)
biomeGrid.SortOrder = Enum.SortOrder.LayoutOrder
biomeGrid.FillDirectionMaxCells = 2
biomeGrid.Parent = biomeContainer

-- Message shown when Natural (random world gen) is selected
local naturalMessage = Instance.new("Frame")
naturalMessage.Name = "NaturalMessage"
naturalMessage.Size = UDim2.new(1, 0, 0, 80)
naturalMessage.BackgroundColor3 = MC.innerBg
naturalMessage.BorderSizePixel = 0
naturalMessage.LayoutOrder = 3
naturalMessage.Visible = false
naturalMessage.Parent = leftColumn
addMinecraftBorder(naturalMessage, MC.innerHighlight, MC.innerShadow, 2)

local naturalMsgText = Instance.new("TextLabel")
naturalMsgText.Size = UDim2.new(1, -16, 1, -8)
naturalMsgText.Position = UDim2.new(0, 8, 0, 4)
naturalMsgText.BackgroundTransparency = 1
naturalMsgText.Text = "Generates a random terrain\nwith multiple biomes"
naturalMsgText.TextColor3 = MC.textDim
naturalMsgText.TextSize = IsMobile and 10 or 11
naturalMsgText.Font = FONT
naturalMsgText.TextWrapped = true
naturalMsgText.TextYAlignment = Enum.TextYAlignment.Center
naturalMsgText.Parent = naturalMessage
addTextShadow(naturalMsgText, "Generates a random terrain\nwith multiple biomes", naturalMsgText.TextSize, FONT, 1, 1)

-- ============================================
-- RIGHT: Environment Settings
-- ============================================
local envTitle = Instance.new("TextLabel")
envTitle.Size = UDim2.new(1, 0, 0, 16)
envTitle.BackgroundTransparency = 1
envTitle.Text = "Environment Settings"
envTitle.TextColor3 = hasPremium and MC.text or MC.textDim
envTitle.TextSize = IsMobile and 10 or 11
envTitle.Font = FONT
envTitle.TextXAlignment = Enum.TextXAlignment.Left
envTitle.LayoutOrder = 1
envTitle.Parent = rightColumn
addTextShadow(envTitle, envTitle.Text, envTitle.TextSize, FONT, 1, 1)

-- Weather
local weatherSection = Instance.new("Frame")
weatherSection.Size = UDim2.new(1, 0, 0, 0)
weatherSection.BackgroundTransparency = 1
weatherSection.AutomaticSize = Enum.AutomaticSize.Y
weatherSection.LayoutOrder = 2
weatherSection.Parent = rightColumn

local weatherLabel = Instance.new("TextLabel")
weatherLabel.Size = UDim2.new(1, 0, 0, 14)
weatherLabel.BackgroundTransparency = 1
weatherLabel.Text = "Weather"
weatherLabel.TextColor3 = MC.textDim
weatherLabel.TextSize = IsMobile and 9 or 10
weatherLabel.Font = FONT
weatherLabel.TextXAlignment = Enum.TextXAlignment.Left
weatherLabel.Parent = weatherSection
addTextShadow(weatherLabel, "Weather", weatherLabel.TextSize, FONT, 1, 1)

local weatherContainer = Instance.new("Frame")
weatherContainer.Size = UDim2.new(1, 0, 0, 0)
weatherContainer.Position = UDim2.new(0, 0, 0, 16)
weatherContainer.BackgroundTransparency = 1
weatherContainer.AutomaticSize = Enum.AutomaticSize.Y
weatherContainer.Parent = weatherSection

local weatherGrid = Instance.new("UIGridLayout")
weatherGrid.CellSize = UDim2.new(0.5, -3, 0, 30)
weatherGrid.CellPadding = UDim2.new(0, 6, 0, 4)
weatherGrid.SortOrder = Enum.SortOrder.LayoutOrder
weatherGrid.Parent = weatherContainer

local weatherPad = Instance.new("Frame")
weatherPad.Size = UDim2.new(1, 0, 0, 16)
weatherPad.BackgroundTransparency = 1
weatherPad.LayoutOrder = 999
weatherPad.Parent = weatherSection

-- Season
local seasonSection = Instance.new("Frame")
seasonSection.Size = UDim2.new(1, 0, 0, 0)
seasonSection.BackgroundTransparency = 1
seasonSection.AutomaticSize = Enum.AutomaticSize.Y
seasonSection.LayoutOrder = 3
seasonSection.Parent = rightColumn

local seasonLabel = Instance.new("TextLabel")
seasonLabel.Size = UDim2.new(1, 0, 0, 14)
seasonLabel.BackgroundTransparency = 1
seasonLabel.Text = "Season"
seasonLabel.TextColor3 = MC.textDim
seasonLabel.TextSize = IsMobile and 9 or 10
seasonLabel.Font = FONT
seasonLabel.TextXAlignment = Enum.TextXAlignment.Left
seasonLabel.Parent = seasonSection
addTextShadow(seasonLabel, "Season", seasonLabel.TextSize, FONT, 1, 1)

local seasonContainer = Instance.new("Frame")
seasonContainer.Size = UDim2.new(1, 0, 0, 0)
seasonContainer.Position = UDim2.new(0, 0, 0, 16)
seasonContainer.BackgroundTransparency = 1
seasonContainer.AutomaticSize = Enum.AutomaticSize.Y
seasonContainer.Parent = seasonSection

local seasonGrid = Instance.new("UIGridLayout")
seasonGrid.CellSize = UDim2.new(0.5, -3, 0, 30)
seasonGrid.CellPadding = UDim2.new(0, 6, 0, 4)
seasonGrid.SortOrder = Enum.SortOrder.LayoutOrder
seasonGrid.Parent = seasonContainer

local seasonPad = Instance.new("Frame")
seasonPad.Size = UDim2.new(1, 0, 0, 16)
seasonPad.BackgroundTransparency = 1
seasonPad.LayoutOrder = 999
seasonPad.Parent = seasonSection

-- Premium Lock Overlay
local premiumLockOverlay = Instance.new("Frame")
premiumLockOverlay.Name = "PremiumLockOverlay"
premiumLockOverlay.Size = UDim2.new(1, 8, 1, -20)
premiumLockOverlay.Position = UDim2.new(0, -4, 0, 20)
premiumLockOverlay.BackgroundColor3 = MC.panelBg
premiumLockOverlay.BackgroundTransparency = 0.4
premiumLockOverlay.BorderSizePixel = 0
premiumLockOverlay.ZIndex = 5
premiumLockOverlay.Visible = not hasPremium
premiumLockOverlay.Active = true
premiumLockOverlay.Parent = rightColumn

local lockIcon = Instance.new("TextLabel")
lockIcon.Size = UDim2.new(1, 0, 0, 24)
lockIcon.Position = UDim2.new(0, 0, 0.3, -20)
lockIcon.BackgroundTransparency = 1
lockIcon.Text = "Locked"
lockIcon.TextColor3 = MC.textDim
lockIcon.TextSize = IsMobile and 16 or 18
lockIcon.Font = FONT
lockIcon.ZIndex = 6
lockIcon.Parent = premiumLockOverlay
addTextShadow(lockIcon, "Locked", lockIcon.TextSize, FONT)

local lockText = Instance.new("TextLabel")
lockText.Size = UDim2.new(1, -10, 0, 28)
lockText.Position = UDim2.new(0, 5, 0.3, 10)
lockText.BackgroundTransparency = 1
lockText.Text = "Requires Advanced Terrain"
lockText.TextColor3 = MC.textDim
lockText.TextSize = IsMobile and 9 or 10
lockText.Font = FONT
lockText.TextWrapped = true
lockText.ZIndex = 6
lockText.Parent = premiumLockOverlay

local getPremiumBtn = createMCButton("GetPremium", "Get Premium", premiumLockOverlay,
	UDim2.new(0.8, 0, 0, 30), {
		normal = MC.greenNormal, hover = MC.greenHover,
		highlight = MC.greenHighlight, shadow = MC.greenShadow,
	})
getPremiumBtn.Position = UDim2.new(0.1, 0, 0.3, 44)
getPremiumBtn.ZIndex = 6

getPremiumBtn.MouseButton1Click:Connect(function()
	if PREMIUM_GAMEPASS_ID > 0 then
		MarketplaceService:PromptGamePassPurchase(player, PREMIUM_GAMEPASS_ID)
	end
end)

-- ============================================
-- ROW 3: Reset Plot (Full Width)
-- ============================================
regenerateSection = Instance.new("Frame")
regenerateSection.Name = "RegenerateSection"
regenerateSection.Size = UDim2.new(1, 0, 0, 58)
regenerateSection.BackgroundTransparency = 1
regenerateSection.LayoutOrder = 3
regenerateSection.Visible = true
regenerateSection.Parent = content

regenerateBtn = createMCButton("ResetPlot", "Reset Plot", regenerateSection,
	UDim2.new(1, 0, 0, 36), {
		normal = MC.yellowNormal, hover = MC.yellowHover,
		highlight = MC.yellowHighlight, shadow = MC.yellowShadow,
	})
regenerateBtn.Position = UDim2.new(0, 0, 0, 0)

local regenerateDesc = Instance.new("TextLabel")
regenerateDesc.Size = UDim2.new(1, 0, 0, 16)
regenerateDesc.Position = UDim2.new(0, 0, 0, 40)
regenerateDesc.BackgroundTransparency = 1
regenerateDesc.Text = "Erases all blocks and regenerates terrain"
regenerateDesc.TextColor3 = MC.textDim
regenerateDesc.TextSize = IsMobile and 9 or 10
regenerateDesc.Font = FONT
regenerateDesc.Parent = regenerateSection
addTextShadow(regenerateDesc, regenerateDesc.Text, regenerateDesc.TextSize, FONT, 1, 1)

-- ============================================
-- ROW 4: Seed Section (Premium only)
-- ============================================
local seedSection = Instance.new("Frame")
seedSection.Name = "SeedSection"
seedSection.Size = UDim2.new(1, 0, 0, 52)
seedSection.BackgroundTransparency = 1
seedSection.LayoutOrder = 4
seedSection.Visible = hasPremium
seedSection.Parent = content

local seedLabel = Instance.new("TextLabel")
seedLabel.Size = UDim2.new(1, 0, 0, 14)
seedLabel.BackgroundTransparency = 1
seedLabel.Text = "World Seed (for terrain generation)"
seedLabel.TextColor3 = MC.textDim
seedLabel.TextSize = IsMobile and 9 or 10
seedLabel.Font = FONT
seedLabel.TextXAlignment = Enum.TextXAlignment.Left
seedLabel.Parent = seedSection
addTextShadow(seedLabel, seedLabel.Text, seedLabel.TextSize, FONT, 1, 1)

local seedInputRow = Instance.new("Frame")
seedInputRow.Size = UDim2.new(1, 0, 0, 32)
seedInputRow.Position = UDim2.new(0, 0, 0, 18)
seedInputRow.BackgroundTransparency = 1
seedInputRow.Parent = seedSection

-- Seed input wrapper (borders outside TextBox)
local seedWrapper = Instance.new("Frame")
seedWrapper.Size = UDim2.new(1, -82, 1, 0)
seedWrapper.BackgroundColor3 = MC.innerBg
seedWrapper.BorderSizePixel = 0
seedWrapper.Parent = seedInputRow
addMinecraftBorder(seedWrapper, MC.innerShadow, MC.innerHighlight, 2)

local seedInput = Instance.new("TextBox")
seedInput.Size = UDim2.new(1, -8, 1, -4)
seedInput.Position = UDim2.new(0, 6, 0, 2)
seedInput.BackgroundTransparency = 1
seedInput.Text = tostring(currentSeed)
seedInput.PlaceholderText = "Seed..."
seedInput.TextColor3 = MC.text
seedInput.PlaceholderColor3 = MC.textDim
seedInput.TextSize = IsMobile and 11 or 12
seedInput.Font = FONT
seedInput.ClearTextOnFocus = false
seedInput.Parent = seedWrapper

local randomizeBtn = createMCButton("Random", "Random", seedInputRow,
	UDim2.new(0, 74, 1, 0), {
		normal = MC.greenNormal, hover = MC.greenHover,
		highlight = MC.greenHighlight, shadow = MC.greenShadow,
	})
randomizeBtn.Position = UDim2.new(1, -74, 0, 0)

-- ============================================
-- OPTION BUTTONS (Weather/Season) - MC style
-- ============================================
local UpdatePlotEnvironment = nil
task.spawn(function()
	UpdatePlotEnvironment = Remotes:WaitForChild("UpdatePlotEnvironment", 10)
end)

local function applyEnvironment()
	if hasPremium and UpdatePlotEnvironment then
		UpdatePlotEnvironment:FireServer(selectedWeather, selectedSeason)
	end
end

local function createOptionButton(parent, option, isSelected, onSelect)
	local btn = Instance.new("TextButton")
	btn.BackgroundColor3 = isSelected and MC.selectedBg or MC.btnNormal
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.Parent = parent
	
	local borders = addMinecraftBorder(btn,
		isSelected and MC.selectedHighlight or MC.btnHighlight,
		isSelected and MC.selectedShadow or MC.btnShadow, 2)
	
	local fg = Instance.new("TextLabel")
	fg.Name = "TextForeground"
	fg.Size = UDim2.new(1, 0, 1, 0)
	fg.BackgroundTransparency = 1
	fg.Text = option.name
	fg.TextColor3 = MC.text
	fg.TextSize = IsMobile and 10 or 11
	fg.Font = FONT
	fg.ZIndex = btn.ZIndex + 2
	fg.Parent = btn
	
	local sh = Instance.new("TextLabel")
	sh.Name = "TextShadow"
	sh.Size = UDim2.new(1, 0, 1, 0)
	sh.Position = UDim2.new(0, 1, 0, 1)
	sh.BackgroundTransparency = 1
	sh.Text = option.name
	sh.TextColor3 = MC.textShadow
	sh.TextSize = IsMobile and 10 or 11
	sh.Font = FONT
	sh.ZIndex = btn.ZIndex + 1
	sh.Parent = btn
	
	btn.MouseButton1Click:Connect(function()
		onSelect(option.id, btn)
	end)
	
	btn.MouseEnter:Connect(function()
		if not btn:GetAttribute("Selected") then
			btn.BackgroundColor3 = MC.btnHover
		end
	end)
	btn.MouseLeave:Connect(function()
		if not btn:GetAttribute("Selected") then
			btn.BackgroundColor3 = MC.btnNormal
		end
	end)
	
	return btn, borders
end

-- Weather Buttons
local weatherButtons = {}
local weatherBorders = {}
for i, opt in ipairs(WeatherOptions) do
	local btn, borders = createOptionButton(weatherContainer, opt, opt.id == selectedWeather, function(id)
		if not hasPremium then return end
		selectedWeather = id
		for optId, b in pairs(weatherButtons) do
			local brd = weatherBorders[optId]
			if optId == id then
				b.BackgroundColor3 = MC.selectedBg
				b:SetAttribute("Selected", true)
				if brd then
					brd.top.BackgroundColor3 = MC.selectedHighlight
					brd.left.BackgroundColor3 = MC.selectedHighlight
					brd.bottom.BackgroundColor3 = MC.selectedShadow
					brd.right.BackgroundColor3 = MC.selectedShadow
				end
			else
				b.BackgroundColor3 = MC.btnNormal
				b:SetAttribute("Selected", false)
				if brd then
					brd.top.BackgroundColor3 = MC.btnHighlight
					brd.left.BackgroundColor3 = MC.btnHighlight
					brd.bottom.BackgroundColor3 = MC.btnShadow
					brd.right.BackgroundColor3 = MC.btnShadow
				end
			end
		end
		applyEnvironment()
	end)
	btn.LayoutOrder = i
	if opt.id == selectedWeather then btn:SetAttribute("Selected", true) end
	weatherButtons[opt.id] = btn
	weatherBorders[opt.id] = borders
end

-- Season Buttons
local seasonButtons = {}
local seasonBorders = {}
for i, opt in ipairs(SeasonOptions) do
	local btn, borders = createOptionButton(seasonContainer, opt, opt.id == selectedSeason, function(id)
		if not hasPremium then return end
		selectedSeason = id
		for optId, b in pairs(seasonButtons) do
			local brd = seasonBorders[optId]
			if optId == id then
				b.BackgroundColor3 = MC.selectedBg
				b:SetAttribute("Selected", true)
				if brd then
					brd.top.BackgroundColor3 = MC.selectedHighlight
					brd.left.BackgroundColor3 = MC.selectedHighlight
					brd.bottom.BackgroundColor3 = MC.selectedShadow
					brd.right.BackgroundColor3 = MC.selectedShadow
				end
			else
				b.BackgroundColor3 = MC.btnNormal
				b:SetAttribute("Selected", false)
				if brd then
					brd.top.BackgroundColor3 = MC.btnHighlight
					brd.left.BackgroundColor3 = MC.btnHighlight
					brd.bottom.BackgroundColor3 = MC.btnShadow
					brd.right.BackgroundColor3 = MC.btnShadow
				end
			end
		end
		applyEnvironment()
	end)
	btn.LayoutOrder = i
	if opt.id == selectedSeason then btn:SetAttribute("Selected", true) end
	seasonButtons[opt.id] = btn
	seasonBorders[opt.id] = borders
end

-- ============================================
-- CONFIRMATION DIALOG (MC style)
-- ============================================
local confirmOverlay = Instance.new("Frame")
confirmOverlay.Name = "ConfirmOverlay"
confirmOverlay.Size = UDim2.new(1, 0, 1, 0)
confirmOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
confirmOverlay.BackgroundTransparency = 0.4
confirmOverlay.BorderSizePixel = 0
confirmOverlay.Visible = false
confirmOverlay.ZIndex = 10
confirmOverlay.Parent = screenGui

local confirmFrame = Instance.new("Frame")
confirmFrame.Size = IsMobile and UDim2.new(0.85, 0, 0, 160) or UDim2.new(0, 340, 0, 160)
confirmFrame.AnchorPoint = Vector2.new(0.5, 0.5)
confirmFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
confirmFrame.BackgroundColor3 = MC.panelBg
confirmFrame.BorderSizePixel = 0
confirmFrame.ZIndex = 11
confirmFrame.Parent = confirmOverlay
addMinecraftBorder(confirmFrame, MC.panelHighlight, MC.panelShadow)

if IsMobile then
	local sc = Instance.new("UISizeConstraint")
	sc.MaxSize = Vector2.new(380, 170)
	sc.Parent = confirmFrame
end

local confirmTitle = Instance.new("TextLabel")
confirmTitle.Size = UDim2.new(1, 0, 0, 36)
confirmTitle.BackgroundTransparency = 1
confirmTitle.Text = "Warning"
confirmTitle.TextColor3 = MC.textWarning
confirmTitle.TextSize = IsMobile and 14 or 16
confirmTitle.Font = FONT
confirmTitle.ZIndex = 12
confirmTitle.Parent = confirmFrame
addTextShadow(confirmTitle, "Warning", confirmTitle.TextSize, FONT)

local confirmText = Instance.new("TextLabel")
confirmText.Size = UDim2.new(1, -20, 0, 40)
confirmText.Position = UDim2.new(0, 10, 0, 38)
confirmText.BackgroundTransparency = 1
confirmText.Text = "This will erase all blocks!\nAre you sure?"
confirmText.TextColor3 = MC.text
confirmText.TextSize = IsMobile and 11 or 12
confirmText.Font = FONT
confirmText.TextWrapped = true
confirmText.ZIndex = 12
confirmText.Parent = confirmFrame
addTextShadow(confirmText, confirmText.Text, confirmText.TextSize, FONT, 1, 1)

local confirmBtnRow = Instance.new("Frame")
confirmBtnRow.Size = UDim2.new(1, -20, 0, 36)
confirmBtnRow.Position = UDim2.new(0, 10, 1, -46)
confirmBtnRow.BackgroundTransparency = 1
confirmBtnRow.ZIndex = 12
confirmBtnRow.Parent = confirmFrame

local confirmYes = createMCButton("ConfirmYes", "Yes, Reset", confirmBtnRow,
	UDim2.new(0.5, -4, 1, 0), {
		normal = MC.redNormal, hover = MC.redHover,
		highlight = MC.redHighlight, shadow = MC.redShadow,
	})
confirmYes.Position = UDim2.new(0, 0, 0, 0)
confirmYes.ZIndex = 12

local confirmNo = createMCButton("ConfirmNo", "Cancel", confirmBtnRow,
	UDim2.new(0.5, -4, 1, 0), {
		normal = MC.closeNormal, hover = MC.closeHover,
		highlight = MC.closeHighlight, shadow = MC.closeShadow,
	})
confirmNo.Position = UDim2.new(0.5, 4, 0, 0)
confirmNo.ZIndex = 12

-- ============================================
-- BIOME BUTTONS (MC style cards)
-- ============================================
local highlightSelectedBiome

local biomeButtons = {}
local biomeBorders = {}
local sortedBiomes = {}
for biomeName, biomeData in pairs(BiomeConfig.Biomes) do
	if biomeName ~= "Flat" then
		table.insert(sortedBiomes, {name = biomeName, data = biomeData, order = biomeData.SortOrder or 99})
	end
end
table.sort(sortedBiomes, function(a, b) return a.order < b.order end)

for i, biomeInfo in ipairs(sortedBiomes) do
	local biomeName = biomeInfo.name
	local biomeData = biomeInfo.data
	local baseColor = BiomeColors[biomeName] or MC.btnNormal
	
	-- Derive highlight/shadow from biome color
	local bH = Color3.new(
		math.min(baseColor.R + 0.15, 1),
		math.min(baseColor.G + 0.15, 1),
		math.min(baseColor.B + 0.15, 1)
	)
	local bS = Color3.new(
		math.max(baseColor.R - 0.15, 0),
		math.max(baseColor.G - 0.15, 0),
		math.max(baseColor.B - 0.15, 0)
	)
	
	local btn = Instance.new("TextButton")
	btn.Name = biomeName
	btn.LayoutOrder = biomeInfo.order
	btn.BackgroundColor3 = baseColor
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.BorderSizePixel = 0
	btn.Parent = biomeContainer
	
	local borders = addMinecraftBorder(btn, bH, bS, 2)
	
	-- Checkmark for multi-select
	local checkmark = Instance.new("TextLabel")
	checkmark.Name = "Checkmark"
	checkmark.Size = UDim2.new(0, 16, 0, 16)
	checkmark.Position = UDim2.new(1, -20, 0, 4)
	checkmark.BackgroundColor3 = MC.greenNormal
	checkmark.Text = ">"
	checkmark.TextColor3 = MC.text
	checkmark.TextSize = 10
	checkmark.Font = FONT
	checkmark.ZIndex = 3
	checkmark.Visible = false
	checkmark.Parent = btn
	addMinecraftBorder(checkmark, MC.greenHighlight, MC.greenShadow, 1)
	
	-- Dark overlay behind text for readability
	local textOverlay = Instance.new("Frame")
	textOverlay.Name = "TextOverlay"
	textOverlay.Size = UDim2.new(1, -4, 1, -4)
	textOverlay.Position = UDim2.new(0, 2, 0, 2)
	textOverlay.BackgroundColor3 = Color3.new(0, 0, 0)
	textOverlay.BackgroundTransparency = 0.45
	textOverlay.BorderSizePixel = 0
	textOverlay.ZIndex = 1
	textOverlay.Parent = btn
	
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -8, 0, 20)
	nameLabel.Position = UDim2.new(0, 6, 0, 4)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = biomeData.DisplayName
	nameLabel.TextColor3 = MC.text
	nameLabel.TextSize = IsMobile and 12 or 14
	nameLabel.Font = FONT
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
	nameLabel.ZIndex = 2
	nameLabel.Parent = btn
	addTextShadow(nameLabel, biomeData.DisplayName, nameLabel.TextSize, FONT, 1, 1)
	
	local descLabel = Instance.new("TextLabel")
	descLabel.Size = UDim2.new(1, -8, 0, 26)
	descLabel.Position = UDim2.new(0, 6, 0, 28)
	descLabel.BackgroundTransparency = 1
	descLabel.Text = biomeData.Description
	descLabel.TextColor3 = Color3.fromRGB(210, 210, 210)
	descLabel.TextSize = IsMobile and 9 or 11
	descLabel.Font = FONT
	descLabel.TextWrapped = true
	descLabel.TextXAlignment = Enum.TextXAlignment.Left
	descLabel.TextYAlignment = Enum.TextYAlignment.Top
	descLabel.ZIndex = 2
	descLabel.Parent = btn
	addTextShadow(descLabel, biomeData.Description, descLabel.TextSize, FONT, 1, 1)
	
	biomeButtons[biomeName] = btn
	biomeBorders[biomeName] = borders
	
	btn.MouseButton1Click:Connect(function()
		if not currentPlot then return end
		selectedBiome = biomeName
		highlightSelectedBiome()
		if selectedTerrainStyle == "Flat" then
			ApplyBiomeColors:FireServer(biomeName, selectedSeason)
		end
	end)
	
	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3 = baseColor:Lerp(Color3.new(1, 1, 1), 0.12)
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = baseColor
	end)
end

-- ============================================
-- SYNC COLUMN HEIGHTS
-- ============================================
local function syncColumnHeights()
	task.defer(function()
		local leftHeight = leftLayout.AbsoluteContentSize.Y
		local rightHeight = rightLayout.AbsoluteContentSize.Y
		local maxHeight = math.max(leftHeight, rightHeight)
		columnsRow.Size = UDim2.new(1, 0, 0, maxHeight)
	end)
end

leftLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(syncColumnHeights)
rightLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(syncColumnHeights)
syncColumnHeights()

-- ============================================
-- EVENT HANDLERS
-- ============================================
randomizeBtn.MouseButton1Click:Connect(function()
	currentSeed = math.random(1, 999999)
	seedInput.Text = tostring(currentSeed)
end)

seedInput.FocusLost:Connect(function()
	local num = tonumber(seedInput.Text)
	if num then
		currentSeed = math.floor(math.abs(num))
		seedInput.Text = tostring(currentSeed)
	else
		seedInput.Text = tostring(currentSeed)
	end
end)

confirmYes.MouseButton1Click:Connect(function()
	if pendingBiome then
		local seed = tonumber(seedInput.Text) or currentSeed
		SelectBiome:FireServer(pendingBiome, selectedTerrainStyle, seed, selectedWeather, selectedSeason, nil)
		pendingBiome = nil
	end
	confirmOverlay.Visible = false
	closeUI()
end)

confirmNo.MouseButton1Click:Connect(function()
	pendingBiome = nil
	confirmOverlay.Visible = false
	mainFrame.Visible = true
end)

closeBtn.MouseButton1Click:Connect(function() closeUI() end)

overlay.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		if not confirmOverlay.Visible then
			closeUI()
		end
	end
end)

highlightSelectedBiome = function()
	for name, btn in pairs(biomeButtons) do
		local borders = biomeBorders[name]
		local checkmark = btn:FindFirstChild("Checkmark")
		local baseColor = BiomeColors[name] or MC.btnNormal
		local bH = Color3.new(
			math.min(baseColor.R + 0.15, 1),
			math.min(baseColor.G + 0.15, 1),
			math.min(baseColor.B + 0.15, 1)
		)
		local bS = Color3.new(
			math.max(baseColor.R - 0.15, 0),
			math.max(baseColor.G - 0.15, 0),
			math.max(baseColor.B - 0.15, 0)
		)
		
		if checkmark then checkmark.Visible = false end
		if borders then
			if name == selectedBiome then
				borders.top.BackgroundColor3 = MC.greenHighlight
				borders.left.BackgroundColor3 = MC.greenHighlight
				borders.bottom.BackgroundColor3 = MC.greenShadow
				borders.right.BackgroundColor3 = MC.greenShadow
			elseif name == currentBiome then
				borders.top.BackgroundColor3 = Color3.fromRGB(80, 160, 80)
				borders.left.BackgroundColor3 = Color3.fromRGB(80, 160, 80)
				borders.bottom.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
				borders.right.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
			else
				borders.top.BackgroundColor3 = bH
				borders.left.BackgroundColor3 = bH
				borders.bottom.BackgroundColor3 = bS
				borders.right.BackgroundColor3 = bS
			end
		end
	end
end

updateBiomeMode = function()
	if selectedTerrainStyle == "Flat" then
		updateShadowText(biomeLabel, "Biome (click to apply colors)")
		biomeHint.Visible = false
		biomeContainer.Visible = true
		naturalMessage.Visible = false
	elseif selectedTerrainStyle == "Natural" then
		-- Single Biome mode
		updateShadowText(biomeLabel, "Biome (select terrain type)")
		biomeHint.Visible = false
		biomeContainer.Visible = true
		naturalMessage.Visible = false
	elseif selectedTerrainStyle == "Default" then
		-- Natural / random world gen mode
		updateShadowText(biomeLabel, "World Generation")
		biomeHint.Visible = false
		biomeContainer.Visible = false
		naturalMessage.Visible = true
	end
	highlightSelectedBiome()
end

regenerateBtn.MouseButton1Click:Connect(function()
	if not currentPlot then return end
	if selectedTerrainStyle == "Default" then
		pendingBiome = "Default"
		confirmOverlay.Visible = true
		mainFrame.Visible = false
	elseif selectedBiome then
		pendingBiome = selectedBiome
		confirmOverlay.Visible = true
		mainFrame.Visible = false
	end
end)

local function selectWeather(id)
	selectedWeather = id
	for optId, b in pairs(weatherButtons) do
		local brd = weatherBorders[optId]
		if optId == id then
			b.BackgroundColor3 = MC.selectedBg
			b:SetAttribute("Selected", true)
			if brd then
				brd.top.BackgroundColor3 = MC.selectedHighlight
				brd.left.BackgroundColor3 = MC.selectedHighlight
				brd.bottom.BackgroundColor3 = MC.selectedShadow
				brd.right.BackgroundColor3 = MC.selectedShadow
			end
		else
			b.BackgroundColor3 = MC.btnNormal
			b:SetAttribute("Selected", false)
			if brd then
				brd.top.BackgroundColor3 = MC.btnHighlight
				brd.left.BackgroundColor3 = MC.btnHighlight
				brd.bottom.BackgroundColor3 = MC.btnShadow
				brd.right.BackgroundColor3 = MC.btnShadow
			end
		end
	end
end

local function selectSeason(id)
	selectedSeason = id
	for optId, b in pairs(seasonButtons) do
		local brd = seasonBorders[optId]
		if optId == id then
			b.BackgroundColor3 = MC.selectedBg
			b:SetAttribute("Selected", true)
			if brd then
				brd.top.BackgroundColor3 = MC.selectedHighlight
				brd.left.BackgroundColor3 = MC.selectedHighlight
				brd.bottom.BackgroundColor3 = MC.selectedShadow
				brd.right.BackgroundColor3 = MC.selectedShadow
			end
		else
			b.BackgroundColor3 = MC.btnNormal
			b:SetAttribute("Selected", false)
			if brd then
				brd.top.BackgroundColor3 = MC.btnHighlight
				brd.left.BackgroundColor3 = MC.btnHighlight
				brd.bottom.BackgroundColor3 = MC.btnShadow
				brd.right.BackgroundColor3 = MC.btnShadow
			end
		end
	end
end

-- ============================================
-- OPEN UI HANDLER
-- ============================================
OpenBiomeUI.OnClientEvent:Connect(function(plotNumber, currentBiomeName, blocksExist, plotWeather, plotSeason, plotTerrainStyle)
	hasPremium = checkPremiumOwnership()
	
	print(string.format("[BiomeSelectionUI] Received: plotTerrainStyle=%s, biome=%s",
		tostring(plotTerrainStyle), tostring(currentBiomeName)))
	
	currentPlot = plotNumber
	currentBiome = currentBiomeName
	selectedBiome = currentBiomeName
	hasExistingBlocks = blocksExist or false
	preferredBiomes = {}
	
	updateShadowText(title, "Plot " .. plotNumber .. " Setup")
	currentSeed = math.random(1, 999999)
	seedInput.Text = tostring(currentSeed)
	
	if plotTerrainStyle then
		initialTerrainStyle = plotTerrainStyle
		selectedTerrainStyle = plotTerrainStyle
	else
		initialTerrainStyle = "Flat"
		selectedTerrainStyle = "Flat"
	end
	
	updateTerrainSelection()
	
	defaultBtn.Text = hasPremium and "Single Biome" or "Single Biome (Locked)"
	naturalBtn.Text = hasPremium and "Natural" or "Natural (Locked)"
	updateShadowText(envTitle, "Environment Settings")
	premiumLockOverlay.Visible = not hasPremium
	seedSection.Visible = hasPremium
	
	if plotWeather then selectWeather(plotWeather) end
	if plotSeason then selectSeason(plotSeason) end
	
	highlightSelectedBiome()
	confirmOverlay.Visible = false
	mainFrame.Visible = true
	pendingBiome = nil
	
	syncColumnHeights()
	openUI()
end)

print("[BiomeSelectionUI] Minecraft-style initialized")
