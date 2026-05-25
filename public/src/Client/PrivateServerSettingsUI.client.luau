--[[
	PrivateServerSettingsUI
	Minecraft "Select World" Style - Owner-only Plot Management for private servers
	
	Opened from the Title Screen (no floating button)
	
	Features:
	- Minecraft-style world list with selectable entries
	- Bottom button rows: Play/Create New, Save/Regenerate/Delete/Cancel
	- Regenerate with New Seed or Same Seed
	- Create New World sub-page (terrain, biome settings)
	- Mode switch (Individual Plots vs Mega-Plot)
	- Weather & Season cosmetic settings
	
	Only accessible to the private server owner
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Wait for private server values
local isPrivateServerValue = ReplicatedStorage:WaitForChild("IsPrivateServer", 10)
local ownerIdValue = ReplicatedStorage:WaitForChild("PrivateServerOwnerId", 10)
local modeValue = ReplicatedStorage:WaitForChild("PrivateServerMode", 10)

-- Exit if not a private server
if not isPrivateServerValue or not isPrivateServerValue.Value then
	print("[PrivateServerSettingsUI] Not a private server, exiting")
	return
end

-- Check if current player is owner
local function waitForOwner()
	if ownerIdValue and ownerIdValue.Value ~= 0 then
		return ownerIdValue.Value == player.UserId
	end
	local maxWait = 15
	local waited = 0
	while ownerIdValue and ownerIdValue.Value == 0 and waited < maxWait do
		task.wait(0.5)
		waited = waited + 0.5
	end
	if not ownerIdValue or ownerIdValue.Value == 0 then return false end
	return ownerIdValue.Value == player.UserId
end

local amOwner = waitForOwner()
if not amOwner then
	print("[PrivateServerSettingsUI] Not the server owner")
	return
end

print("[PrivateServerSettingsUI] Player is owner, initializing settings UI")

-- Load configs
local BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
local PrivateServerConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PrivateServerConfig"))
local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local ApplyPrivateServerSettings = Remotes:WaitForChild("ApplyPrivateServerSettings", 10)
local UpdateCosmetics = Remotes:FindFirstChild("UpdateCosmetics")

-- Mega Plot slot remotes
local GetMegaPlotSlots = Remotes:FindFirstChild("GetMegaPlotSlots")
local SaveMegaPlotToSlot = Remotes:FindFirstChild("SaveMegaPlotToSlot")
local LoadMegaPlotFromSlot = Remotes:FindFirstChild("LoadMegaPlotFromSlot")
local DeleteMegaPlotSlot = Remotes:FindFirstChild("DeleteMegaPlotSlot")
local MegaPlotSlotResult = Remotes:FindFirstChild("MegaPlotSlotResult")

-- ============================================
-- PREMIUM CHECK
-- ============================================
local PREMIUM_GAMEPASS_ID = 1676832631
local hasPremium = false

local function checkPremiumOwnership()
	if player.UserId == game.CreatorId then return true end
	if BetaConfig.IS_BETA then return true end
	if PREMIUM_GAMEPASS_ID == 0 then return false end
	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, PREMIUM_GAMEPASS_ID)
	end)
	return success and owns
end

hasPremium = checkPremiumOwnership()

-- ============================================
-- STATE
-- ============================================
local isUIOpen = false
local currentPage = "main" -- "main" or "createNew"
local selectedMode = modeValue and modeValue.Value or "Individual"
local initialMode = selectedMode
local selectedTerrainStyle = "Default"
local initialTerrainStyle = selectedTerrainStyle
local selectedBiome = "Plains"
local selectedWeather = "Clear"
local selectedSeason = "Summer"
local selectedSlotIndex = nil -- 1-3, which world entry is highlighted
local pendingWorldSlot = nil -- slot number for a world being auto-saved
local pendingWorldInfo = nil -- {name, biome, terrainStyle} for immediate display
local isSetupMode = false -- opened from title screen vs in-game
local createPageFromTitle = false -- true when create page opened via title screen

-- Mega plot slot data
local MAX_FREE_SLOTS = 3
local megaPlotSlots = {} -- populated from server

-- Biome list sorted
local BIOMES = {}
local BIOME_DISPLAY = {}
if BiomeConfig.Biomes then
	local tempBiomes = {}
	for name, config in pairs(BiomeConfig.Biomes) do
		table.insert(tempBiomes, {name = name, order = config.SortOrder or 99, display = config.DisplayName})
	end
	table.sort(tempBiomes, function(a, b) return a.order < b.order end)
	for _, b in ipairs(tempBiomes) do
		table.insert(BIOMES, b.name)
		BIOME_DISPLAY[b.name] = b.display
	end
end

local TERRAIN_STYLES = {"Default", "Flat", "Biome"}
local TERRAIN_DISPLAY = {Default = "Default", Flat = "Flat", Biome = "Single Biome"}
local WEATHERS = {"Clear", "Rain", "Snow", "Fog"}
local SEASONS = {"Spring", "Summer", "Autumn", "Winter"}
local MODES = {"Individual", "MegaPlot"}
local MODE_DISPLAY = {Individual = "Individual Plots", MegaPlot = "Mega-Plot"}
local MODE_DESC = {Individual = "9 separate build plots for players", MegaPlot = "One giant shared building area"}

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

-- ============================================
-- MC STYLE COLORS
-- ============================================
local MC = {
	PanelBG = Color3.fromRGB(0, 0, 0),
	BtnFace = Color3.fromRGB(110, 110, 110),
	BtnHover = Color3.fromRGB(130, 130, 150),
	BtnDisabled = Color3.fromRGB(45, 45, 45),
	BorderLight = Color3.fromRGB(170, 170, 170),
	BorderDark = Color3.fromRGB(50, 50, 50),
	BorderHoverLight = Color3.fromRGB(190, 190, 220),
	White = Color3.fromRGB(255, 255, 255),
	Gray = Color3.fromRGB(160, 160, 160),
	Yellow = Color3.fromRGB(255, 255, 85),
	DarkShadow = Color3.fromRGB(60, 60, 60),
	DisabledText = Color3.fromRGB(100, 100, 100),
	Gold = Color3.fromRGB(255, 170, 0),
	GreenFace = Color3.fromRGB(60, 130, 60),
	GreenLight = Color3.fromRGB(100, 190, 100),
	GreenDark = Color3.fromRGB(30, 70, 30),
	RedFace = Color3.fromRGB(150, 50, 50),
	RedLight = Color3.fromRGB(200, 80, 80),
	RedDark = Color3.fromRGB(80, 30, 30),
	BlueFace = Color3.fromRGB(50, 90, 150),
	BlueLight = Color3.fromRGB(80, 130, 200),
	BlueDark = Color3.fromRGB(30, 50, 80),
	SepColor = Color3.fromRGB(80, 80, 80),
	SlotBG = Color3.fromRGB(30, 30, 35),
	SlotSelected = Color3.fromRGB(45, 45, 55),
	SlotBorder = Color3.fromRGB(60, 60, 70),
	SlotEmpty = Color3.fromRGB(80, 80, 80),
}

-- ============================================
-- FORWARD DECLARES
-- ============================================
local closeUI, openUI, showMainPage, showCreateNewPage
local updateMegaPlotSection, updateButtonStates, selectSlot, refreshSlotData

-- ============================================
-- INSTANT COSMETIC UPDATE
-- ============================================
local function fireInstantCosmetic()
	if not UpdateCosmetics then return end
	UpdateCosmetics:FireServer({
		biome = selectedBiome,
		season = selectedSeason,
		weather = selectedWeather,
	})
end

-- ============================================
-- DEVICE DETECTION
-- ============================================
local mobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

-- ============================================
-- SCREEN GUI
-- ============================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PrivateServerSettingsUI"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 150
screenGui.Parent = playerGui

-- ============================================
-- DARK OVERLAY (full screen background)
-- ============================================
local overlay = Instance.new("Frame")
overlay.Name = "Overlay"
overlay.Size = UDim2.new(1, 0, 1, 0)
overlay.BackgroundColor3 = Color3.fromRGB(15, 12, 10)
overlay.BackgroundTransparency = 0
overlay.BorderSizePixel = 0
overlay.ZIndex = 1
overlay.Parent = screenGui

-- ============================================
-- MAIN PANEL (full screen)
-- ============================================
local mainPanel = Instance.new("Frame")
mainPanel.Name = "MainPanel"
mainPanel.AnchorPoint = Vector2.new(0.5, 0.5)
mainPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
mainPanel.Size = UDim2.new(1, 0, 1, 0)
mainPanel.BackgroundColor3 = Color3.fromRGB(20, 18, 16)
mainPanel.BackgroundTransparency = 0.15
mainPanel.BorderSizePixel = 0
mainPanel.ClipsDescendants = true
mainPanel.ZIndex = 2
mainPanel.Parent = screenGui

-- Layout constants
local CONTENT_MAX_WIDTH = 520
local CONTENT_PADDING = mobile and 16 or 40
local TITLE_HEIGHT = mobile and 52 or 60
local BTN_HEIGHT = mobile and 32 or 36
local BOTTOM_AREA = (BTN_HEIGHT * 2) + 4 + 20 -- 2 rows + gap + padding
local SCROLL_TOP = TITLE_HEIGHT + 4
local SCROLL_BOTTOM = BOTTOM_AREA + 4

-- ============================================
-- SEPARATORS (top & bottom)
-- ============================================
-- Top/bottom separators removed for cleaner look

-- ============================================
-- TITLE
-- ============================================
local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT - 8)
titleLabel.Position = UDim2.new(0, 0, 0, 4)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Select World"
titleLabel.TextColor3 = MC.White
titleLabel.TextSize = mobile and 22 or 26
titleLabel.Font = Enum.Font.Arcade
titleLabel.ZIndex = 3
titleLabel.Parent = mainPanel

local titleShadow = titleLabel:Clone()
titleShadow.Name = "TitleShadow"
titleShadow.Position = UDim2.new(0, 2, 0, 6)
titleShadow.TextColor3 = MC.DarkShadow
titleShadow.ZIndex = 2
titleShadow.Parent = mainPanel

-- ============================================
-- MC BUTTON FACTORY
-- ============================================
local function createMCButton(parent, text, size, position, layoutOrder, onClick)
	local container = Instance.new("Frame")
	container.Size = size or UDim2.new(1, 0, 0, BTN_HEIGHT)
	if position then container.Position = position end
	if layoutOrder then container.LayoutOrder = layoutOrder end
	container.BackgroundTransparency = 1
	container.ZIndex = 3
	container.Parent = parent

	local btn = Instance.new("TextButton")
	btn.Name = "MCBtn"
	btn.Size = UDim2.new(1, 0, 1, 0)
	btn.BackgroundColor3 = MC.BtnFace
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.ZIndex = 4
	btn.Parent = container

	local topB = Instance.new("Frame")
	topB.Name = "TopB"; topB.Size = UDim2.new(1, 0, 0, 2)
	topB.BackgroundColor3 = MC.BorderLight; topB.BorderSizePixel = 0; topB.ZIndex = 5; topB.Parent = btn

	local leftB = Instance.new("Frame")
	leftB.Name = "LeftB"; leftB.Size = UDim2.new(0, 2, 1, 0)
	leftB.BackgroundColor3 = MC.BorderLight; leftB.BorderSizePixel = 0; leftB.ZIndex = 5; leftB.Parent = btn

	local bottomB = Instance.new("Frame")
	bottomB.Name = "BottomB"; bottomB.Size = UDim2.new(1, 0, 0, 2); bottomB.Position = UDim2.new(0, 0, 1, -2)
	bottomB.BackgroundColor3 = MC.BorderDark; bottomB.BorderSizePixel = 0; bottomB.ZIndex = 5; bottomB.Parent = btn

	local rightB = Instance.new("Frame")
	rightB.Name = "RightB"; rightB.Size = UDim2.new(0, 2, 1, 0); rightB.Position = UDim2.new(1, -2, 0, 0)
	rightB.BackgroundColor3 = MC.BorderDark; rightB.BorderSizePixel = 0; rightB.ZIndex = 5; rightB.Parent = btn

	local txtShadow = Instance.new("TextLabel")
	txtShadow.Name = "TxtShadow"; txtShadow.Size = UDim2.new(1, 0, 1, 0)
	txtShadow.Position = UDim2.new(0, 2, 0, 2); txtShadow.BackgroundTransparency = 1
	txtShadow.Text = text; txtShadow.TextColor3 = MC.DarkShadow
	txtShadow.TextSize = mobile and 12 or 14; txtShadow.Font = Enum.Font.Arcade
	txtShadow.ZIndex = 5; txtShadow.Parent = btn

	local txtLabel = Instance.new("TextLabel")
	txtLabel.Name = "TxtLabel"; txtLabel.Size = UDim2.new(1, 0, 1, 0)
	txtLabel.BackgroundTransparency = 1; txtLabel.Text = text; txtLabel.TextColor3 = MC.White
	txtLabel.TextSize = mobile and 12 or 14; txtLabel.Font = Enum.Font.Arcade
	txtLabel.ZIndex = 6; txtLabel.Parent = btn

	local isEnabled = true

	-- Store hover connections so applyColorScheme can replace them
	local hoverEnterConn, hoverLeaveConn

	local function connectHoverHandlers(face, light, hoverFace, hoverLight)
		if hoverEnterConn then hoverEnterConn:Disconnect() end
		if hoverLeaveConn then hoverLeaveConn:Disconnect() end
		hoverEnterConn = btn.MouseEnter:Connect(function()
			if not isEnabled then return end
			btn.BackgroundColor3 = hoverFace
			topB.BackgroundColor3 = hoverLight; leftB.BackgroundColor3 = hoverLight
		end)
		hoverLeaveConn = btn.MouseLeave:Connect(function()
			if not isEnabled then return end
			btn.BackgroundColor3 = face
			topB.BackgroundColor3 = light; leftB.BackgroundColor3 = light
		end)
	end

	-- Default grey hover
	connectHoverHandlers(MC.BtnFace, MC.BorderLight, MC.BtnHover, MC.BorderHoverLight)

	if onClick then btn.MouseButton1Click:Connect(onClick) end

	-- Track current colors for SetEnabled
	local curFace, curLight, curDark = MC.BtnFace, MC.BorderLight, MC.BorderDark

	local api = {
		Container = container, Button = btn,
		TxtLabel = txtLabel, TxtShadow = txtShadow,
		TopB = topB, LeftB = leftB, BottomB = bottomB, RightB = rightB,
	}

	function api:SetText(t) txtLabel.Text = t; txtShadow.Text = t end

	function api:SetEnabled(e)
		isEnabled = e
		if e then
			btn.BackgroundColor3 = curFace; txtLabel.TextColor3 = MC.White; txtShadow.TextColor3 = MC.DarkShadow
			topB.BackgroundColor3 = curLight; leftB.BackgroundColor3 = curLight
			bottomB.BackgroundColor3 = curDark; rightB.BackgroundColor3 = curDark
		else
			btn.BackgroundColor3 = MC.BtnDisabled; txtLabel.TextColor3 = MC.DisabledText; txtShadow.TextColor3 = Color3.fromRGB(25, 25, 25)
			topB.BackgroundColor3 = Color3.fromRGB(65, 65, 65); leftB.BackgroundColor3 = Color3.fromRGB(65, 65, 65)
			bottomB.BackgroundColor3 = Color3.fromRGB(25, 25, 25); rightB.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
		end
	end

	function api:IsEnabled() return isEnabled end

	local function applyColorScheme(face, light, dark, hoverFace, hoverLight)
		curFace = face; curLight = light; curDark = dark
		btn.BackgroundColor3 = face
		topB.BackgroundColor3 = light; leftB.BackgroundColor3 = light
		bottomB.BackgroundColor3 = dark; rightB.BackgroundColor3 = dark
		-- Replace hover handlers with new colors (disconnect old, connect new)
		connectHoverHandlers(face, light, hoverFace, hoverLight)
	end

	function api:SetGreen() applyColorScheme(MC.GreenFace, MC.GreenLight, MC.GreenDark, Color3.fromRGB(80,160,80), Color3.fromRGB(130,220,130)) end
	function api:SetRed() applyColorScheme(MC.RedFace, MC.RedLight, MC.RedDark, Color3.fromRGB(180,70,70), Color3.fromRGB(220,100,100)) end
	function api:SetBlue() applyColorScheme(MC.BlueFace, MC.BlueLight, MC.BlueDark, Color3.fromRGB(70,110,180), Color3.fromRGB(100,150,220)) end

	return api
end

-- ============================================
-- CYCLING OPTION ROW FACTORY
-- ============================================
local function createCycleRow(parent, label, options, displayMap, startValue, layoutOrder, onChanged)
	local currentIndex = 1
	for i, opt in ipairs(options) do
		if opt == startValue then currentIndex = i; break end
	end

	local function getDisplayText()
		local val = options[currentIndex]
		local display = displayMap and displayMap[val] or val
		return label .. ": " .. display
	end

	local mcBtn
	local function cycle()
		currentIndex = currentIndex % #options + 1
		local newVal = options[currentIndex]
		mcBtn:SetText(getDisplayText())
		if onChanged then onChanged(newVal) end
	end

	mcBtn = createMCButton(parent, getDisplayText(), UDim2.new(1, 0, 0, BTN_HEIGHT), nil, layoutOrder, cycle)
	local api = { MCBtn = mcBtn, Row = mcBtn.Container }
	function api:SetValue(val)
		for i, opt in ipairs(options) do if opt == val then currentIndex = i; break end end
		mcBtn:SetText(getDisplayText())
	end
	function api:GetValue() return options[currentIndex] end
	function api:SetEnabled(e) mcBtn:SetEnabled(e) end
	function api:SetLocked() mcBtn:SetEnabled(false); mcBtn:SetText(label .. ": 🔒 Locked") end
	return api
end

-- ============================================
-- HELPERS
-- ============================================
local sepCount = 0
local function createSeparator(parent, layoutOrder)
	sepCount += 1
	local sep = Instance.new("Frame")
	sep.Name = "Sep" .. sepCount; sep.Size = UDim2.new(1, 0, 0, 14)
	sep.BackgroundTransparency = 1; sep.LayoutOrder = layoutOrder; sep.ZIndex = 3; sep.Parent = parent
	local line = Instance.new("Frame")
	line.Size = UDim2.new(0.5, 0, 0, 1); line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.Position = UDim2.new(0.5, 0, 0.5, 0); line.BackgroundColor3 = MC.SepColor
	line.BackgroundTransparency = 0.4; line.BorderSizePixel = 0; line.ZIndex = 3; line.Parent = sep
	return sep
end

local function createSectionLabel(parent, text, layoutOrder, color)
	local lbl = Instance.new("TextLabel")
	lbl.Name = "Section_" .. text:gsub("%s+", "")
	lbl.Size = UDim2.new(1, 0, 0, 20)
	lbl.BackgroundTransparency = 1; lbl.Text = text
	lbl.TextColor3 = color or MC.Gray; lbl.TextSize = 13
	lbl.Font = Enum.Font.Arcade; lbl.LayoutOrder = layoutOrder; lbl.ZIndex = 3
	lbl.Parent = parent
	return lbl
end

local function createDescLabel(parent, text, layoutOrder)
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, 0, 0, 14); lbl.BackgroundTransparency = 1; lbl.Text = text
	lbl.TextColor3 = MC.Gray; lbl.TextSize = 11; lbl.Font = Enum.Font.Arcade
	lbl.LayoutOrder = layoutOrder; lbl.ZIndex = 3; lbl.Parent = parent
	return lbl
end

-- ============================================
-- SCROLLABLE CONTENT AREA (MAIN PAGE)
-- ============================================
local scrollFrame = Instance.new("ScrollingFrame")
scrollFrame.Name = "OptionsScroll"
scrollFrame.AnchorPoint = Vector2.new(0.5, 0)
scrollFrame.Size = UDim2.new(1, -CONTENT_PADDING * 2, 1, -(SCROLL_TOP + SCROLL_BOTTOM))
scrollFrame.Position = UDim2.new(0.5, 0, 0, SCROLL_TOP)
scrollFrame.BackgroundColor3 = Color3.fromRGB(10, 10, 12); scrollFrame.BackgroundTransparency = 0.3; scrollFrame.BorderSizePixel = 0
scrollFrame.ScrollBarThickness = 4; scrollFrame.ScrollBarImageColor3 = MC.Gray
scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y
scrollFrame.ZIndex = 3; scrollFrame.Parent = mainPanel

local scrollConstraint = Instance.new("UISizeConstraint")
scrollConstraint.MaxSize = Vector2.new(CONTENT_MAX_WIDTH, 99999)
scrollConstraint.Parent = scrollFrame

local content = Instance.new("Frame")
content.Size = UDim2.new(1, 0, 0, 0); content.BackgroundTransparency = 1
content.AutomaticSize = Enum.AutomaticSize.Y; content.ZIndex = 3
content.Parent = scrollFrame

local contentLayout = Instance.new("UIListLayout")
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder; contentLayout.Padding = UDim.new(0, 4)
contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center; contentLayout.Parent = content

-- Server Mode section removed (mode switching is on the title screen now)

-- ============================================
-- === SECTION: WORLD LIST (Mega-Plot only) ===
-- ============================================
local worldSection = Instance.new("Frame")
worldSection.Name = "WorldSection"
worldSection.Size = UDim2.new(1, 0, 0, 0)
worldSection.AutomaticSize = Enum.AutomaticSize.Y
worldSection.BackgroundTransparency = 1
worldSection.LayoutOrder = 10
worldSection.ZIndex = 3
worldSection.Visible = (selectedMode == "MegaPlot")
worldSection.Parent = content

local worldLayout = Instance.new("UIListLayout")
worldLayout.SortOrder = Enum.SortOrder.LayoutOrder
worldLayout.Padding = UDim.new(0, 4)
worldLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
worldLayout.Parent = worldSection

-- "Saved Worlds" header removed for cleaner look

-- World entry creation
local ENTRY_HEIGHT = mobile and 64 or 72
local THUMB_SIZE = mobile and 44 or 52
local worldEntries = {} -- indexed by slot number

local function createWorldEntry(slotNumber)
	local entry = Instance.new("TextButton")
	entry.Name = "World" .. slotNumber
	entry.Size = UDim2.new(1, 0, 0, ENTRY_HEIGHT)
	entry.BackgroundColor3 = MC.SlotBG
	entry.BackgroundTransparency = 0.2
	entry.Text = ""
	entry.AutoButtonColor = false
	entry.BorderSizePixel = 0
	entry.LayoutOrder = 10 + slotNumber
	entry.ZIndex = 4
	entry.Parent = worldSection

	-- Selection stroke
	local stroke = Instance.new("UIStroke")
	stroke.Name = "SelectStroke"
	stroke.Color = MC.SlotBorder
	stroke.Thickness = 1
	stroke.Parent = entry

	-- Biome color thumbnail
	local thumb = Instance.new("Frame")
	thumb.Name = "Thumb"
	thumb.Size = UDim2.new(0, THUMB_SIZE, 0, THUMB_SIZE)
	thumb.Position = UDim2.new(0, 10, 0.5, -THUMB_SIZE / 2)
	thumb.BackgroundColor3 = MC.SlotEmpty
	thumb.BorderSizePixel = 0
	thumb.ZIndex = 5
	thumb.Parent = entry
	Instance.new("UICorner", thumb).CornerRadius = UDim.new(0, 4)

	local thumbStroke = Instance.new("UIStroke")
	thumbStroke.Color = Color3.fromRGB(50, 50, 50)
	thumbStroke.Thickness = 1
	thumbStroke.Parent = thumb

	-- Biome initial letter on thumbnail
	local thumbText = Instance.new("TextLabel")
	thumbText.Size = UDim2.new(1, 0, 1, 0)
	thumbText.BackgroundTransparency = 1
	thumbText.Text = ""
	thumbText.TextColor3 = MC.White
	thumbText.TextSize = mobile and 18 or 22
	thumbText.Font = Enum.Font.Arcade
	thumbText.ZIndex = 6
	thumbText.Parent = thumb

	-- World name
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "Name"
	nameLabel.Size = UDim2.new(1, -(THUMB_SIZE + 30), 0, 20)
	nameLabel.Position = UDim2.new(0, THUMB_SIZE + 20, 0, mobile and 8 or 10)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = "Empty Slot"
	nameLabel.TextColor3 = MC.SlotEmpty
	nameLabel.TextSize = mobile and 14 or 16
	nameLabel.Font = Enum.Font.Arcade
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.ZIndex = 5
	nameLabel.Parent = entry

	-- Info line (biome, terrain, blocks)
	local infoLabel = Instance.new("TextLabel")
	infoLabel.Name = "Info"
	infoLabel.Size = UDim2.new(1, -(THUMB_SIZE + 30), 0, 14)
	infoLabel.Position = UDim2.new(0, THUMB_SIZE + 20, 0, mobile and 28 or 32)
	infoLabel.BackgroundTransparency = 1
	infoLabel.Text = "No saved data"
	infoLabel.TextColor3 = MC.Gray
	infoLabel.TextSize = mobile and 10 or 11
	infoLabel.Font = Enum.Font.Arcade
	infoLabel.TextXAlignment = Enum.TextXAlignment.Left
	infoLabel.ZIndex = 5
	infoLabel.Parent = entry

	-- Date line
	local dateLabel = Instance.new("TextLabel")
	dateLabel.Name = "Date"
	dateLabel.Size = UDim2.new(1, -(THUMB_SIZE + 30), 0, 14)
	dateLabel.Position = UDim2.new(0, THUMB_SIZE + 20, 0, mobile and 42 or 48)
	dateLabel.BackgroundTransparency = 1
	dateLabel.Text = ""
	dateLabel.TextColor3 = Color3.fromRGB(120, 120, 120)
	dateLabel.TextSize = mobile and 9 or 10
	dateLabel.Font = Enum.Font.Arcade
	dateLabel.TextXAlignment = Enum.TextXAlignment.Left
	dateLabel.ZIndex = 5
	dateLabel.Parent = entry

	-- Click to select
	local lastClickTime = 0
	entry.MouseButton1Click:Connect(function()
		local now = tick()
		if now - lastClickTime < 0.4 and selectedSlotIndex == slotNumber then
			-- Double-click: play this world (if it has data)
			local slotInfo = megaPlotSlots[slotNumber]
			if slotInfo and slotInfo.hasData then
				-- Fire load
				if not LoadMegaPlotFromSlot then
					LoadMegaPlotFromSlot = Remotes:FindFirstChild("LoadMegaPlotFromSlot")
				end
				if LoadMegaPlotFromSlot then
					LoadMegaPlotFromSlot:FireServer(slotNumber)
				end
			end
		else
			selectSlot(slotNumber)
		end
		lastClickTime = now
	end)

	-- Hover effect
	entry.MouseEnter:Connect(function()
		if selectedSlotIndex ~= slotNumber then
			TweenService:Create(entry, TweenInfo.new(0.08), {BackgroundColor3 = Color3.fromRGB(40, 40, 48)}):Play()
		end
	end)
	entry.MouseLeave:Connect(function()
		if selectedSlotIndex ~= slotNumber then
			TweenService:Create(entry, TweenInfo.new(0.08), {BackgroundColor3 = MC.SlotBG}):Play()
		end
	end)

	worldEntries[slotNumber] = {
		frame = entry,
		stroke = stroke,
		thumb = thumb,
		thumbText = thumbText,
		nameLabel = nameLabel,
		infoLabel = infoLabel,
		dateLabel = dateLabel,
	}
end

for i = 1, MAX_FREE_SLOTS do
	createWorldEntry(i)
end

-- Empty state message (shown when no worlds have data)
local emptyStateLabel = Instance.new("TextLabel")
emptyStateLabel.Name = "EmptyState"
emptyStateLabel.Size = UDim2.new(1, 0, 0, 80)
emptyStateLabel.BackgroundTransparency = 1
emptyStateLabel.Text = "No saved worlds yet.\nClick \"Create New World\" to get started!"
emptyStateLabel.TextColor3 = MC.Gray
emptyStateLabel.TextSize = mobile and 14 or 16
emptyStateLabel.Font = Enum.Font.Arcade
emptyStateLabel.TextWrapped = true
emptyStateLabel.LayoutOrder = 20
emptyStateLabel.ZIndex = 3
emptyStateLabel.Visible = true
-- Parent to mainPanel instead of worldSection so it can be centered on screen
emptyStateLabel.Parent = mainPanel
emptyStateLabel.AnchorPoint = Vector2.new(0.5, 0.5)
emptyStateLabel.Position = UDim2.new(0.5, 0, 0.45, 0)
emptyStateLabel.Size = UDim2.new(0.8, 0, 0, 80)

-- Individual mode placeholder
local individualLabel = Instance.new("TextLabel")
individualLabel.Size = UDim2.new(1, 0, 0, 40)
individualLabel.BackgroundTransparency = 1
individualLabel.Text = "Individual plots have separate save slots per player.\nUse the in-game Save/Load button."
individualLabel.TextColor3 = MC.Gray
individualLabel.TextSize = 12
individualLabel.Font = Enum.Font.Arcade
individualLabel.TextWrapped = true
individualLabel.LayoutOrder = 11
individualLabel.ZIndex = 3
individualLabel.Visible = false
individualLabel.Parent = content

-- Separator before environment (hidden, environment moved to Settings page)
-- createSeparator(content, 30)

-- ============================================
-- === SECTION: WEATHER & SEASON (hidden from main page, shown in Settings page) ===
-- ============================================
-- These are kept for variable compatibility but hidden from the worlds main page
local envRow = Instance.new("Frame")
envRow.Size = UDim2.new(1, 0, 0, BTN_HEIGHT)
envRow.BackgroundTransparency = 1
envRow.LayoutOrder = 32; envRow.ZIndex = 3; envRow.Visible = false; envRow.Parent = content

local seasonRow = createCycleRow(
	envRow, "Season", SEASONS, nil, selectedSeason, 1,
	function(newSeason)
		if not hasPremium then
			seasonRow:SetValue(selectedSeason)
			if PREMIUM_GAMEPASS_ID > 0 then MarketplaceService:PromptGamePassPurchase(player, PREMIUM_GAMEPASS_ID) end
			return
		end
		selectedSeason = newSeason
		fireInstantCosmetic()
	end
)
seasonRow.Row.Size = UDim2.new(0.5, -3, 1, 0)
seasonRow.Row.Position = UDim2.new(0, 0, 0, 0)

local weatherRow = createCycleRow(
	envRow, "Weather", WEATHERS, nil, selectedWeather, 2,
	function(newWeather)
		if not hasPremium then
			weatherRow:SetValue(selectedWeather)
			if PREMIUM_GAMEPASS_ID > 0 then MarketplaceService:PromptGamePassPurchase(player, PREMIUM_GAMEPASS_ID) end
			return
		end
		selectedWeather = newWeather
		fireInstantCosmetic()
	end
)
weatherRow.Row.Size = UDim2.new(0.5, -3, 1, 0)
weatherRow.Row.Position = UDim2.new(0.5, 3, 0, 0)

local premiumNote = Instance.new("TextLabel")
premiumNote.Size = UDim2.new(1, 0, 0, 14); premiumNote.BackgroundTransparency = 1
premiumNote.Text = "🔒 Season & Weather require Advanced Terrain gamepass"
premiumNote.TextColor3 = MC.Gray; premiumNote.TextSize = 10; premiumNote.Font = Enum.Font.Arcade
premiumNote.LayoutOrder = 33; premiumNote.Visible = false; premiumNote.ZIndex = 3
premiumNote.Parent = content

-- Bottom spacer
local spacer = Instance.new("Frame")
spacer.Size = UDim2.new(1, 0, 0, 10); spacer.BackgroundTransparency = 1
spacer.LayoutOrder = 99; spacer.Parent = content

-- ============================================
-- BOTTOM BUTTONS - ROW 1: Play / Create New
-- ============================================
local btnRow1 = Instance.new("Frame")
btnRow1.Name = "BtnRow1"
btnRow1.AnchorPoint = Vector2.new(0.5, 0)
btnRow1.Size = UDim2.new(1, -CONTENT_PADDING * 2, 0, BTN_HEIGHT)
btnRow1.Position = UDim2.new(0.5, 0, 1, -(BOTTOM_AREA))
btnRow1.BackgroundTransparency = 1
btnRow1.ZIndex = 3
btnRow1.Parent = mainPanel

local btnRow1Constraint = Instance.new("UISizeConstraint")
btnRow1Constraint.MaxSize = Vector2.new(CONTENT_MAX_WIDTH, BTN_HEIGHT)
btnRow1Constraint.Parent = btnRow1

local playWorldBtn = createMCButton(btnRow1, "Play Selected World", UDim2.new(0.5, -3, 1, 0), UDim2.new(0, 0, 0, 0))
playWorldBtn:SetBlue()
playWorldBtn:SetEnabled(false) -- disabled until a world is selected

local createNewBtn = createMCButton(btnRow1, "Create New World", UDim2.new(0.5, -3, 1, 0), UDim2.new(0.5, 3, 0, 0))
createNewBtn:SetGreen()

-- ============================================
-- BOTTOM BUTTONS - ROW 2: Save / Regenerate / Delete / Cancel
-- ============================================
local btnRow2 = Instance.new("Frame")
btnRow2.Name = "BtnRow2"
btnRow2.AnchorPoint = Vector2.new(0.5, 0)
btnRow2.Size = UDim2.new(1, -CONTENT_PADDING * 2, 0, BTN_HEIGHT)
btnRow2.Position = UDim2.new(0.5, 0, 1, -(BOTTOM_AREA - BTN_HEIGHT - 4))
btnRow2.BackgroundTransparency = 1
btnRow2.ZIndex = 3
btnRow2.Parent = mainPanel

local btnRow2Constraint = Instance.new("UISizeConstraint")
btnRow2Constraint.MaxSize = Vector2.new(CONTENT_MAX_WIDTH, BTN_HEIGHT)
btnRow2Constraint.Parent = btnRow2

local saveBtnWidth = UDim2.new(0.25, -5, 1, 0)
local saveBtn = createMCButton(btnRow2, "Save", saveBtnWidth, UDim2.new(0, 0, 0, 0))
saveBtn:SetGreen()
saveBtn:SetEnabled(false)

local regenBtn = createMCButton(btnRow2, "Regenerate", UDim2.new(0.25, -5, 1, 0), UDim2.new(0.25, 2, 0, 0))

local deleteBtn = createMCButton(btnRow2, "Delete", UDim2.new(0.25, -5, 1, 0), UDim2.new(0.5, 4, 0, 0))
deleteBtn:SetRed()
deleteBtn:SetEnabled(false)

local cancelBtn = createMCButton(btnRow2, "Cancel", UDim2.new(0.25, -5, 1, 0), UDim2.new(0.75, 6, 0, 0))

-- ============================================
-- SELECTION LOGIC
-- ============================================
function selectSlot(index)
	selectedSlotIndex = index
	-- Update visual highlights
	for i, entry in pairs(worldEntries) do
		if i == index then
			entry.stroke.Color = MC.White
			entry.stroke.Thickness = 2
			entry.frame.BackgroundColor3 = MC.SlotSelected
		else
			entry.stroke.Color = MC.SlotBorder
			entry.stroke.Thickness = 1
			entry.frame.BackgroundColor3 = MC.SlotBG
		end
	end
	updateButtonStates()
end

function updateButtonStates()
	local hasSelection = selectedSlotIndex ~= nil
	local slotInfo = hasSelection and megaPlotSlots[selectedSlotIndex] or nil
	local slotHasData = slotInfo and slotInfo.hasData

	playWorldBtn:SetEnabled(slotHasData == true)
	-- Save is always enabled in MegaPlot mode (auto-finds next empty slot if no selection)
	saveBtn:SetEnabled(selectedMode == "MegaPlot")
	deleteBtn:SetEnabled(slotHasData == true)
	-- Regen is always enabled in mega plot mode (regenerates current world)
	regenBtn:SetEnabled(selectedMode == "MegaPlot")
end

-- ============================================
-- CONFIRMATION DIALOG (generic)
-- ============================================
local confirmOverlay = Instance.new("Frame")
confirmOverlay.Size = UDim2.new(1, 0, 1, 0)
confirmOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0); confirmOverlay.BackgroundTransparency = 0.35
confirmOverlay.BorderSizePixel = 0; confirmOverlay.Visible = false; confirmOverlay.ZIndex = 10
confirmOverlay.Parent = screenGui

local confirmPanel = Instance.new("Frame")
confirmPanel.Size = mobile and UDim2.new(0.9, 0, 0, 180) or UDim2.new(0, 420, 0, 180)
confirmPanel.AnchorPoint = Vector2.new(0.5, 0.5); confirmPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
confirmPanel.BackgroundColor3 = Color3.fromRGB(20, 18, 16); confirmPanel.BackgroundTransparency = 0.08
confirmPanel.BorderSizePixel = 0; confirmPanel.Visible = false; confirmPanel.ZIndex = 11
confirmPanel.Parent = screenGui
Instance.new("UIStroke", confirmPanel).Color = Color3.fromRGB(80, 80, 80)

local confirmTitle = Instance.new("TextLabel")
confirmTitle.Size = UDim2.new(1, 0, 0, 28); confirmTitle.Position = UDim2.new(0, 0, 0, 14)
confirmTitle.BackgroundTransparency = 1; confirmTitle.Text = "Warning!"
confirmTitle.TextColor3 = MC.Yellow; confirmTitle.TextSize = 18
confirmTitle.Font = Enum.Font.Arcade; confirmTitle.ZIndex = 12; confirmTitle.Parent = confirmPanel

local confirmText = Instance.new("TextLabel")
confirmText.Size = UDim2.new(1, -30, 0, 50); confirmText.Position = UDim2.new(0, 15, 0, 44)
confirmText.BackgroundTransparency = 1; confirmText.Text = ""
confirmText.TextColor3 = MC.White; confirmText.TextSize = 13; confirmText.Font = Enum.Font.Arcade
confirmText.TextWrapped = true; confirmText.ZIndex = 12; confirmText.Parent = confirmPanel

local confirmBtnBar = Instance.new("Frame")
confirmBtnBar.Size = UDim2.new(1, -30, 0, 34); confirmBtnBar.Position = UDim2.new(0, 15, 1, -50)
confirmBtnBar.BackgroundTransparency = 1; confirmBtnBar.ZIndex = 12; confirmBtnBar.Parent = confirmPanel

local confirmYes = createMCButton(confirmBtnBar, "Confirm", UDim2.new(0.5, -3, 1, 0), UDim2.new(0, 0, 0, 0))
confirmYes:SetRed()
for _, child in confirmYes.Button:GetDescendants() do
	if child:IsA("GuiObject") or child:IsA("TextLabel") then child.ZIndex = child.ZIndex + 8 end
end
confirmYes.Button.ZIndex = 12; confirmYes.TxtLabel.ZIndex = 14; confirmYes.TxtShadow.ZIndex = 13

local confirmNo = createMCButton(confirmBtnBar, "Cancel", UDim2.new(0.5, -3, 1, 0), UDim2.new(0.5, 3, 0, 0))
for _, child in confirmNo.Button:GetDescendants() do
	if child:IsA("GuiObject") or child:IsA("TextLabel") then child.ZIndex = child.ZIndex + 8 end
end
confirmNo.Button.ZIndex = 12; confirmNo.TxtLabel.ZIndex = 14; confirmNo.TxtShadow.ZIndex = 13

local function showConfirm() confirmOverlay.Visible = true; confirmPanel.Visible = true end
local function hideConfirm() confirmOverlay.Visible = false; confirmPanel.Visible = false end

-- Track what action the confirm dialog is for
local confirmAction = nil -- "delete", "modeChange", "save_overwrite"

confirmYes.Button.MouseButton1Click:Connect(function()
	hideConfirm()
	if confirmAction == "delete" and selectedSlotIndex then
		if not DeleteMegaPlotSlot then DeleteMegaPlotSlot = Remotes:FindFirstChild("DeleteMegaPlotSlot") end
		if DeleteMegaPlotSlot then DeleteMegaPlotSlot:FireServer(selectedSlotIndex) end
		task.delay(0.5, refreshSlotData)
	elseif confirmAction == "save_overwrite" and selectedSlotIndex then
		if not SaveMegaPlotToSlot then SaveMegaPlotToSlot = Remotes:FindFirstChild("SaveMegaPlotToSlot") end
		if SaveMegaPlotToSlot then SaveMegaPlotToSlot:FireServer(selectedSlotIndex) end
	elseif confirmAction == "modeChange" then
		-- Apply mode change with reset
		ApplyPrivateServerSettings:FireServer({
			mode = selectedMode,
			biome = selectedBiome,
			terrainStyle = selectedTerrainStyle,
			season = selectedSeason,
			weather = selectedWeather,
			confirmReset = "RESET",
		})
		initialMode = selectedMode
		initialTerrainStyle = selectedTerrainStyle
		closeUI()
		startGame()
	end
	confirmAction = nil
end)

confirmNo.Button.MouseButton1Click:Connect(function()
	confirmAction = nil; hideConfirm()
end)

confirmOverlay.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		confirmAction = nil; hideConfirm()
	end
end)

-- ============================================
-- REGENERATE DIALOG (New Seed / Same Seed / Cancel)
-- ============================================
local regenOverlay = Instance.new("Frame")
regenOverlay.Size = UDim2.new(1, 0, 1, 0)
regenOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0); regenOverlay.BackgroundTransparency = 0.35
regenOverlay.BorderSizePixel = 0; regenOverlay.Visible = false; regenOverlay.ZIndex = 10
regenOverlay.Parent = screenGui

local regenPanel = Instance.new("Frame")
regenPanel.Size = mobile and UDim2.new(0.9, 0, 0, 200) or UDim2.new(0, 440, 0, 200)
regenPanel.AnchorPoint = Vector2.new(0.5, 0.5); regenPanel.Position = UDim2.new(0.5, 0, 0.5, 0)
regenPanel.BackgroundColor3 = Color3.fromRGB(20, 18, 16); regenPanel.BackgroundTransparency = 0.08
regenPanel.BorderSizePixel = 0; regenPanel.Visible = false; regenPanel.ZIndex = 11
regenPanel.Parent = screenGui
Instance.new("UIStroke", regenPanel).Color = Color3.fromRGB(80, 80, 80)

local regenTitle = Instance.new("TextLabel")
regenTitle.Size = UDim2.new(1, 0, 0, 28); regenTitle.Position = UDim2.new(0, 0, 0, 14)
regenTitle.BackgroundTransparency = 1; regenTitle.Text = "Regenerate World"
regenTitle.TextColor3 = MC.Yellow; regenTitle.TextSize = 18
regenTitle.Font = Enum.Font.Arcade; regenTitle.ZIndex = 12; regenTitle.Parent = regenPanel

local regenText = Instance.new("TextLabel")
regenText.Size = UDim2.new(1, -30, 0, 44); regenText.Position = UDim2.new(0, 15, 0, 44)
regenText.BackgroundTransparency = 1
regenText.Text = "Regenerate terrain using current settings.\nAll placed blocks will be removed!"
regenText.TextColor3 = MC.White; regenText.TextSize = 13; regenText.Font = Enum.Font.Arcade
regenText.TextWrapped = true; regenText.ZIndex = 12; regenText.Parent = regenPanel

local regenBtnBar = Instance.new("Frame")
regenBtnBar.Size = UDim2.new(1, -30, 0, 34); regenBtnBar.Position = UDim2.new(0, 15, 1, -56)
regenBtnBar.BackgroundTransparency = 1; regenBtnBar.ZIndex = 12; regenBtnBar.Parent = regenPanel

local newSeedBtn = createMCButton(regenBtnBar, "New Random Seed", UDim2.new(0.5, -3, 1, 0), UDim2.new(0, 0, 0, 0))
for _, child in newSeedBtn.Button:GetDescendants() do
	if child:IsA("GuiObject") or child:IsA("TextLabel") then child.ZIndex = child.ZIndex + 8 end
end
newSeedBtn.Button.ZIndex = 12; newSeedBtn.TxtLabel.ZIndex = 14; newSeedBtn.TxtShadow.ZIndex = 13
newSeedBtn:SetGreen()

local sameSeedBtn = createMCButton(regenBtnBar, "Keep Same Seed", UDim2.new(0.5, -3, 1, 0), UDim2.new(0.5, 3, 0, 0))
for _, child in sameSeedBtn.Button:GetDescendants() do
	if child:IsA("GuiObject") or child:IsA("TextLabel") then child.ZIndex = child.ZIndex + 8 end
end
sameSeedBtn.Button.ZIndex = 12; sameSeedBtn.TxtLabel.ZIndex = 14; sameSeedBtn.TxtShadow.ZIndex = 13
sameSeedBtn:SetBlue()

local regenCancelBtn = createMCButton(regenPanel, "Cancel", UDim2.new(1, -30, 0, 30), UDim2.new(0, 15, 1, -18))
for _, child in regenCancelBtn.Button:GetDescendants() do
	if child:IsA("GuiObject") or child:IsA("TextLabel") then child.ZIndex = child.ZIndex + 8 end
end
regenCancelBtn.Button.ZIndex = 12; regenCancelBtn.TxtLabel.ZIndex = 14; regenCancelBtn.TxtShadow.ZIndex = 13

local function showRegenDialog() regenOverlay.Visible = true; regenPanel.Visible = true end
local function hideRegenDialog() regenOverlay.Visible = false; regenPanel.Visible = false end

local function doRegenerate(useNewSeed)
	hideRegenDialog()
	print("[PrivateServerSettingsUI] Regenerating world, newSeed:", useNewSeed)
	ApplyPrivateServerSettings:FireServer({
		mode = "MegaPlot",
		biome = selectedBiome,
		terrainStyle = selectedTerrainStyle,
		season = selectedSeason,
		weather = selectedWeather,
		confirmReset = "RESET",
		newSeed = useNewSeed,
	})
	initialMode = selectedMode
	initialTerrainStyle = selectedTerrainStyle
	closeUI()
	startGame()
end

newSeedBtn.Button.MouseButton1Click:Connect(function() doRegenerate(true) end)
sameSeedBtn.Button.MouseButton1Click:Connect(function() doRegenerate(false) end)
regenCancelBtn.Button.MouseButton1Click:Connect(hideRegenDialog)
regenOverlay.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		hideRegenDialog()
	end
end)

-- ============================================
-- CREATE NEW WORLD PAGE
-- ============================================
local createPage = Instance.new("ScrollingFrame")
createPage.Name = "CreatePage"
createPage.AnchorPoint = Vector2.new(0.5, 0)
createPage.Size = UDim2.new(1, -CONTENT_PADDING * 2, 1, -(SCROLL_TOP + SCROLL_BOTTOM))
createPage.Position = UDim2.new(0.5, 0, 0, SCROLL_TOP)
createPage.BackgroundTransparency = 1; createPage.BorderSizePixel = 0
createPage.ScrollBarThickness = 4; createPage.ScrollBarImageColor3 = MC.Gray
createPage.CanvasSize = UDim2.new(0, 0, 0, 0)
createPage.AutomaticCanvasSize = Enum.AutomaticSize.Y
createPage.ScrollingDirection = Enum.ScrollingDirection.Y
createPage.ZIndex = 3; createPage.Visible = false; createPage.Parent = mainPanel

local createPageConstraint = Instance.new("UISizeConstraint")
createPageConstraint.MaxSize = Vector2.new(CONTENT_MAX_WIDTH, 99999)
createPageConstraint.Parent = createPage

local createContent = Instance.new("Frame")
createContent.Size = UDim2.new(1, 0, 0, 0); createContent.BackgroundTransparency = 1
createContent.AutomaticSize = Enum.AutomaticSize.Y; createContent.ZIndex = 3
createContent.Parent = createPage

local createLayout = Instance.new("UIListLayout")
createLayout.SortOrder = Enum.SortOrder.LayoutOrder; createLayout.Padding = UDim.new(0, 6)
createLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
createLayout.Parent = createContent

createSectionLabel(createContent, "Create New Mega Plot", 1, Color3.fromRGB(100, 255, 100))

-- World Name input
local nameRow = Instance.new("Frame")
nameRow.Size = UDim2.new(1, 0, 0, BTN_HEIGHT + 18)
nameRow.BackgroundTransparency = 1
nameRow.LayoutOrder = 2; nameRow.ZIndex = 3; nameRow.Parent = createContent

local nameLabel = Instance.new("TextLabel")
nameLabel.Size = UDim2.new(1, 0, 0, 16)
nameLabel.BackgroundTransparency = 1; nameLabel.Text = "World Name"
nameLabel.TextColor3 = MC.Gray; nameLabel.TextSize = 11
nameLabel.Font = Enum.Font.Arcade; nameLabel.TextXAlignment = Enum.TextXAlignment.Left
nameLabel.ZIndex = 3; nameLabel.Parent = nameRow

local nameInput = Instance.new("TextBox")
nameInput.Name = "NameInput"
nameInput.Size = UDim2.new(1, 0, 0, BTN_HEIGHT)
nameInput.Position = UDim2.new(0, 0, 0, 18)
nameInput.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
nameInput.BackgroundTransparency = 0
nameInput.BorderSizePixel = 0
nameInput.Text = ""
nameInput.PlaceholderText = "My World"
nameInput.PlaceholderColor3 = Color3.fromRGB(90, 90, 90)
nameInput.TextColor3 = MC.White
nameInput.TextSize = mobile and 14 or 15
nameInput.Font = Enum.Font.Arcade
nameInput.ClearTextOnFocus = false
nameInput.ZIndex = 4
nameInput.Parent = nameRow

local nameInputStroke = Instance.new("UIStroke")
nameInputStroke.Color = MC.SepColor; nameInputStroke.Thickness = 1; nameInputStroke.Parent = nameInput
Instance.new("UICorner", nameInput).CornerRadius = UDim.new(0, 3)
Instance.new("UIPadding", nameInput).PaddingLeft = UDim.new(0, 8)

-- Highlight on focus
nameInput.Focused:Connect(function()
	nameInputStroke.Color = MC.White
end)
nameInput.FocusLost:Connect(function()
	nameInputStroke.Color = MC.SepColor
	-- Sanitize: trim and limit length
	local text = nameInput.Text:gsub("^%s+", ""):gsub("%s+$", "")
	if #text > 30 then text = text:sub(1, 30) end
	nameInput.Text = text
end)

createSeparator(createContent, 3)

-- Terrain style
local newTerrainStyle = "Default"
local newBiome = "Plains"
local newBiomeGrid -- forward declare (created below, referenced in callback)
local newSeedRow -- forward declare for seed input row

local newTerrainRow = createCycleRow(
	createContent, "Terrain", TERRAIN_STYLES, TERRAIN_DISPLAY, newTerrainStyle, 10,
	function(newTerrain)
		if (newTerrain == "Default" or newTerrain == "Biome") and not hasPremium then
			newTerrainRow:SetValue("Flat"); newTerrainStyle = "Flat"
			newBiomeGrid.Visible = false
			if newSeedRow then newSeedRow.Visible = false end
			if PREMIUM_GAMEPASS_ID > 0 then MarketplaceService:PromptGamePassPurchase(player, PREMIUM_GAMEPASS_ID) end
			return
		end
		newTerrainStyle = newTerrain
		-- Only show biome grid for "Biome" (single biome) mode
		newBiomeGrid.Visible = (newTerrain == "Biome")
		-- Show seed input for Default (multi-biome) mode
		if newSeedRow then newSeedRow.Visible = (newTerrain == "Default") end
	end
)

local newTerrainDesc = createDescLabel(createContent, "Default: Multi-biome  •  Flat: Flat grass  •  Biome: Pick one biome", 11)
newTerrainDesc.TextWrapped = true; newTerrainDesc.Size = UDim2.new(1, 0, 0, 18)

-- Seed input row (visible for Default terrain)
newSeedRow = Instance.new("Frame")
newSeedRow.Size = UDim2.new(1, 0, 0, BTN_HEIGHT + 18)
newSeedRow.BackgroundTransparency = 1
newSeedRow.LayoutOrder = 11; newSeedRow.ZIndex = 3; newSeedRow.Visible = true
newSeedRow.Parent = createContent

local seedLabel = Instance.new("TextLabel")
seedLabel.Size = UDim2.new(1, 0, 0, 16)
seedLabel.BackgroundTransparency = 1; seedLabel.Text = "Seed (optional)"
seedLabel.TextColor3 = MC.Gray; seedLabel.TextSize = 11
seedLabel.Font = Enum.Font.Arcade; seedLabel.TextXAlignment = Enum.TextXAlignment.Left
seedLabel.ZIndex = 3; seedLabel.Parent = newSeedRow

local seedInput = Instance.new("TextBox")
seedInput.Name = "SeedInput"
seedInput.Size = UDim2.new(1, 0, 0, BTN_HEIGHT)
seedInput.Position = UDim2.new(0, 0, 0, 18)
seedInput.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
seedInput.BackgroundTransparency = 0
seedInput.BorderSizePixel = 0
seedInput.Text = ""
seedInput.PlaceholderText = "Leave blank for random"
seedInput.PlaceholderColor3 = Color3.fromRGB(90, 90, 90)
seedInput.TextColor3 = MC.White
seedInput.TextSize = mobile and 14 or 15
seedInput.Font = Enum.Font.Arcade
seedInput.ClearTextOnFocus = false
seedInput.ZIndex = 4
seedInput.Parent = newSeedRow

local seedInputStroke = Instance.new("UIStroke")
seedInputStroke.Color = MC.SepColor; seedInputStroke.Thickness = 1; seedInputStroke.Parent = seedInput
Instance.new("UICorner", seedInput).CornerRadius = UDim.new(0, 3)
Instance.new("UIPadding", seedInput).PaddingLeft = UDim.new(0, 8)

seedInput.Focused:Connect(function() seedInputStroke.Color = MC.White end)
seedInput.FocusLost:Connect(function()
	seedInputStroke.Color = MC.SepColor
	-- Only allow numeric input
	local text = seedInput.Text:gsub("%D", "")
	if #text > 10 then text = text:sub(1, 10) end
	seedInput.Text = text
end)

-- Biome grid for "Biome" terrain mode only
newBiomeGrid = Instance.new("Frame")
newBiomeGrid.Name = "NewBiomeGrid"; newBiomeGrid.Size = UDim2.new(1, 0, 0, 0)
newBiomeGrid.AutomaticSize = Enum.AutomaticSize.Y; newBiomeGrid.BackgroundTransparency = 1
newBiomeGrid.LayoutOrder = 12; newBiomeGrid.ZIndex = 3; newBiomeGrid.Visible = false
newBiomeGrid.Parent = createContent

local newGridLayout = Instance.new("UIGridLayout")
newGridLayout.CellSize = UDim2.new(0.5, -4, 0, 30); newGridLayout.CellPadding = UDim2.new(0, 8, 0, 4)
newGridLayout.SortOrder = Enum.SortOrder.LayoutOrder; newGridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
newGridLayout.FillDirection = Enum.FillDirection.Horizontal; newGridLayout.Parent = newBiomeGrid

local newBiomeButtons = {}

local function highlightNewBiome()
	for name, btn in pairs(newBiomeButtons) do
		local base = BiomeColors[name] or MC.BtnFace
		local tB, lB, bB, rB = btn:FindFirstChild("TopB"), btn:FindFirstChild("LeftB"), btn:FindFirstChild("BottomB"), btn:FindFirstChild("RightB")
		if name == newBiome then
			btn.BackgroundColor3 = base:Lerp(Color3.new(1,1,1), 0.25)
			local bright = base:Lerp(Color3.new(1,1,1), 0.55)
			if tB then tB.BackgroundColor3 = bright end; if lB then lB.BackgroundColor3 = bright end
			if bB then bB.BackgroundColor3 = bright end; if rB then rB.BackgroundColor3 = bright end
		else
			btn.BackgroundColor3 = base
			if tB then tB.BackgroundColor3 = base:Lerp(Color3.new(1,1,1), 0.35) end
			if lB then lB.BackgroundColor3 = base:Lerp(Color3.new(1,1,1), 0.35) end
			if bB then bB.BackgroundColor3 = base:Lerp(Color3.new(0,0,0), 0.4) end
			if rB then rB.BackgroundColor3 = base:Lerp(Color3.new(0,0,0), 0.4) end
		end
	end
end

for i, biomeName in ipairs(BIOMES) do
	if biomeName ~= "Flat" then
		local baseColor = BiomeColors[biomeName] or MC.BtnFace
		local btn = Instance.new("TextButton")
		btn.Name = biomeName; btn.LayoutOrder = i; btn.BackgroundColor3 = baseColor
		btn.Text = ""; btn.AutoButtonColor = false; btn.ZIndex = 4; btn.Parent = newBiomeGrid

		local lightBorder = baseColor:Lerp(Color3.new(1,1,1), 0.35)
		local darkBorder = baseColor:Lerp(Color3.new(0,0,0), 0.4)

		local tB = Instance.new("Frame"); tB.Name = "TopB"; tB.Size = UDim2.new(1,0,0,2); tB.BackgroundColor3 = lightBorder; tB.BorderSizePixel = 0; tB.ZIndex = 5; tB.Parent = btn
		local lB = Instance.new("Frame"); lB.Name = "LeftB"; lB.Size = UDim2.new(0,2,1,0); lB.BackgroundColor3 = lightBorder; lB.BorderSizePixel = 0; lB.ZIndex = 5; lB.Parent = btn
		local bB = Instance.new("Frame"); bB.Name = "BottomB"; bB.Size = UDim2.new(1,0,0,2); bB.Position = UDim2.new(0,0,1,-2); bB.BackgroundColor3 = darkBorder; bB.BorderSizePixel = 0; bB.ZIndex = 5; bB.Parent = btn
		local rB = Instance.new("Frame"); rB.Name = "RightB"; rB.Size = UDim2.new(0,2,1,0); rB.Position = UDim2.new(1,-2,0,0); rB.BackgroundColor3 = darkBorder; rB.BorderSizePixel = 0; rB.ZIndex = 5; rB.Parent = btn

		local txtS = Instance.new("TextLabel"); txtS.Size = UDim2.new(1,0,1,0); txtS.Position = UDim2.new(0,2,0,2); txtS.BackgroundTransparency = 1
		txtS.Text = BIOME_DISPLAY[biomeName] or biomeName; txtS.TextColor3 = MC.DarkShadow; txtS.TextSize = 12; txtS.Font = Enum.Font.Arcade; txtS.ZIndex = 6; txtS.Parent = btn

		local txtL = Instance.new("TextLabel"); txtL.Size = UDim2.new(1,0,1,0); txtL.BackgroundTransparency = 1
		txtL.Text = BIOME_DISPLAY[biomeName] or biomeName; txtL.TextColor3 = MC.White; txtL.TextSize = 12; txtL.Font = Enum.Font.Arcade; txtL.ZIndex = 7; txtL.Parent = btn

		newBiomeButtons[biomeName] = btn
		btn.MouseButton1Click:Connect(function() newBiome = biomeName; highlightNewBiome() end)
		btn.MouseEnter:Connect(function()
			if biomeName ~= newBiome then TweenService:Create(btn, TweenInfo.new(0.08), {BackgroundColor3 = baseColor:Lerp(Color3.new(1,1,1), 0.15)}):Play() end
		end)
		btn.MouseLeave:Connect(function()
			if biomeName ~= newBiome then TweenService:Create(btn, TweenInfo.new(0.08), {BackgroundColor3 = baseColor}):Play() end
		end)
	end
end
highlightNewBiome()

createSeparator(createContent, 20)

-- Premium terrain note
local createPremiumNote = Instance.new("TextLabel")
createPremiumNote.Size = UDim2.new(1, 0, 0, 14); createPremiumNote.BackgroundTransparency = 1
createPremiumNote.Text = "🔒 Default & Biome terrain require Advanced Terrain gamepass"
createPremiumNote.TextColor3 = MC.Gray; createPremiumNote.TextSize = 10; createPremiumNote.Font = Enum.Font.Arcade
createPremiumNote.LayoutOrder = 21; createPremiumNote.Visible = not hasPremium; createPremiumNote.ZIndex = 3
createPremiumNote.Parent = createContent

-- Warning
local createWarning = Instance.new("TextLabel")
createWarning.Size = UDim2.new(1, 0, 0, 28); createWarning.BackgroundTransparency = 1
createWarning.Text = "⚠ Creating a new mega plot will erase ALL existing blocks! This cannot be undone."
createWarning.TextColor3 = MC.Yellow; createWarning.TextSize = 11
createWarning.Font = Enum.Font.Arcade; createWarning.TextWrapped = true
createWarning.LayoutOrder = 22; createWarning.ZIndex = 3; createWarning.Parent = createContent

-- Bottom buttons for create page
local createBtnBar = Instance.new("Frame")
createBtnBar.Name = "CreateBtnBar"
createBtnBar.AnchorPoint = Vector2.new(0.5, 0)
createBtnBar.Size = UDim2.new(1, -CONTENT_PADDING * 2, 0, BTN_HEIGHT)
createBtnBar.Position = UDim2.new(0.5, 0, 1, -(BOTTOM_AREA))
createBtnBar.BackgroundTransparency = 1
createBtnBar.ZIndex = 3
createBtnBar.Visible = false
createBtnBar.Parent = mainPanel

local createBtnBarConstraint = Instance.new("UISizeConstraint")
createBtnBarConstraint.MaxSize = Vector2.new(CONTENT_MAX_WIDTH, BTN_HEIGHT)
createBtnBarConstraint.Parent = createBtnBar

local createConfirmBtn = createMCButton(createBtnBar, "Create & Play", UDim2.new(0.5, -3, 1, 0), UDim2.new(0, 0, 0, 0))
createConfirmBtn:SetGreen()

local createBackBtn = createMCButton(createBtnBar, "Back", UDim2.new(0.5, -3, 1, 0), UDim2.new(0.5, 3, 0, 0))

-- ============================================
-- === SETTINGS PAGE (Environment controls) ===
-- ============================================
local settingsPage = Instance.new("ScrollingFrame")
settingsPage.Name = "SettingsPage"
settingsPage.AnchorPoint = Vector2.new(0.5, 0)
settingsPage.Size = UDim2.new(1, -CONTENT_PADDING * 2, 1, -(SCROLL_TOP + SCROLL_BOTTOM))
settingsPage.Position = UDim2.new(0.5, 0, 0, SCROLL_TOP)
settingsPage.BackgroundTransparency = 1; settingsPage.BorderSizePixel = 0
settingsPage.ScrollBarThickness = 4; settingsPage.ScrollBarImageColor3 = MC.Gray
settingsPage.CanvasSize = UDim2.new(0, 0, 0, 0)
settingsPage.AutomaticCanvasSize = Enum.AutomaticSize.Y
settingsPage.ScrollingDirection = Enum.ScrollingDirection.Y
settingsPage.ZIndex = 3; settingsPage.Visible = false; settingsPage.Parent = mainPanel

local settingsPageConstraint = Instance.new("UISizeConstraint")
settingsPageConstraint.MaxSize = Vector2.new(CONTENT_MAX_WIDTH, 99999)
settingsPageConstraint.Parent = settingsPage

local settingsContent = Instance.new("UIListLayout")
settingsContent.SortOrder = Enum.SortOrder.LayoutOrder
settingsContent.Padding = UDim.new(0, 4)
settingsContent.HorizontalAlignment = Enum.HorizontalAlignment.Center
settingsContent.Parent = settingsPage

-- Environment section in settings page
createSectionLabel(settingsPage, "Environment", 1, MC.White)

local settingsEnvRow = Instance.new("Frame")
settingsEnvRow.Size = UDim2.new(1, 0, 0, BTN_HEIGHT)
settingsEnvRow.BackgroundTransparency = 1
settingsEnvRow.LayoutOrder = 2; settingsEnvRow.ZIndex = 3; settingsEnvRow.Parent = settingsPage

local settingsSeasonRow = createCycleRow(
	settingsEnvRow, "Season", SEASONS, nil, selectedSeason, 1,
	function(newSeason)
		if not hasPremium then
			settingsSeasonRow:SetValue(selectedSeason)
			if PREMIUM_GAMEPASS_ID > 0 then MarketplaceService:PromptGamePassPurchase(player, PREMIUM_GAMEPASS_ID) end
			return
		end
		selectedSeason = newSeason
		seasonRow:SetValue(newSeason) -- Keep old row in sync
		fireInstantCosmetic()
	end
)
settingsSeasonRow.Row.Size = UDim2.new(0.5, -3, 1, 0)
settingsSeasonRow.Row.Position = UDim2.new(0, 0, 0, 0)

local settingsWeatherRow = createCycleRow(
	settingsEnvRow, "Weather", WEATHERS, nil, selectedWeather, 2,
	function(newWeather)
		if not hasPremium then
			settingsWeatherRow:SetValue(selectedWeather)
			if PREMIUM_GAMEPASS_ID > 0 then MarketplaceService:PromptGamePassPurchase(player, PREMIUM_GAMEPASS_ID) end
			return
		end
		selectedWeather = newWeather
		weatherRow:SetValue(newWeather) -- Keep old row in sync
		fireInstantCosmetic()
	end
)
settingsWeatherRow.Row.Size = UDim2.new(0.5, -3, 1, 0)
settingsWeatherRow.Row.Position = UDim2.new(0.5, 3, 0, 0)

local settingsPremiumNote = Instance.new("TextLabel")
settingsPremiumNote.Size = UDim2.new(1, 0, 0, 14); settingsPremiumNote.BackgroundTransparency = 1
settingsPremiumNote.Text = "\u{1F512} Season & Weather require Advanced Terrain gamepass"
settingsPremiumNote.TextColor3 = MC.Gray; settingsPremiumNote.TextSize = 10; settingsPremiumNote.Font = Enum.Font.Arcade
settingsPremiumNote.LayoutOrder = 3; settingsPremiumNote.Visible = not hasPremium; settingsPremiumNote.ZIndex = 3
settingsPremiumNote.Parent = settingsPage

createSeparator(settingsPage, 4)

-- Placeholder for future personal settings
local futureSettingsLabel = Instance.new("TextLabel")
futureSettingsLabel.Size = UDim2.new(1, 0, 0, 40); futureSettingsLabel.BackgroundTransparency = 1
futureSettingsLabel.Text = "More settings coming soon!"
futureSettingsLabel.TextColor3 = MC.Gray; futureSettingsLabel.TextSize = 12; futureSettingsLabel.Font = Enum.Font.Arcade
futureSettingsLabel.LayoutOrder = 10; futureSettingsLabel.ZIndex = 3
futureSettingsLabel.Parent = settingsPage

-- Settings button bar
local settingsBtnBar = Instance.new("Frame")
settingsBtnBar.Name = "SettingsBtnBar"
settingsBtnBar.AnchorPoint = Vector2.new(0.5, 0)
settingsBtnBar.Size = UDim2.new(1, -CONTENT_PADDING * 2, 0, BTN_HEIGHT)
settingsBtnBar.Position = UDim2.new(0.5, 0, 1, -(BOTTOM_AREA))
settingsBtnBar.BackgroundTransparency = 1
settingsBtnBar.ZIndex = 3
settingsBtnBar.Visible = false
settingsBtnBar.Parent = mainPanel

local settingsBtnBarConstraint = Instance.new("UISizeConstraint")
settingsBtnBarConstraint.MaxSize = Vector2.new(CONTENT_MAX_WIDTH, BTN_HEIGHT)
settingsBtnBarConstraint.Parent = settingsBtnBar

local settingsDoneBtn = createMCButton(settingsBtnBar, "Done", UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0))

-- ============================================
-- START GAME HELPER
-- ============================================
local function startGame()
	task.wait(0.2)
	if _G.TitleScreen and _G.TitleScreen.IsOpen and _G.TitleScreen.IsOpen() then
		local startGameEvent = ReplicatedStorage:FindFirstChild("StartGame")
		if startGameEvent then startGameEvent:FireServer("Creative") end
		if _G.TitleScreen.Hide then _G.TitleScreen.Hide() end
		if _G.CameraController and _G.CameraController.StartGame then _G.CameraController.StartGame() end
		local megaPlotReady = Remotes:FindFirstChild("MegaPlotPlayerReady")
		if megaPlotReady then megaPlotReady:FireServer() end
	end
end

-- ============================================
-- PAGE NAVIGATION
-- ============================================
function showMainPage()
	currentPage = "main"
	titleLabel.Visible = false; titleShadow.Visible = false
	scrollFrame.Visible = true; createPage.Visible = false; settingsPage.Visible = false
	-- Expand scroll area into the title space
	scrollFrame.Position = UDim2.new(0.5, 0, 0, 8)
	scrollFrame.Size = UDim2.new(1, -CONTENT_PADDING * 2, 1, -(8 + SCROLL_BOTTOM))
	btnRow1.Visible = true; btnRow2.Visible = true; createBtnBar.Visible = false; settingsBtnBar.Visible = false
	updateMegaPlotSection()
	updateButtonStates()
end

function showCreateNewPage()
	currentPage = "createNew"
	titleLabel.Visible = true; titleShadow.Visible = true
	titleLabel.Text = "New Mega Plot"; titleShadow.Text = "New Mega Plot"
	scrollFrame.Visible = false; createPage.Visible = true; settingsPage.Visible = false
	emptyStateLabel.Visible = false
	btnRow1.Visible = false; btnRow2.Visible = false; createBtnBar.Visible = true; settingsBtnBar.Visible = false
	nameInput.Text = ""
	newTerrainStyle = "Default"; newTerrainRow:SetValue("Default")
	newBiome = "Plains"; highlightNewBiome()
	newBiomeGrid.Visible = false -- Default mode has no biome grid
	if newSeedRow then newSeedRow.Visible = hasPremium end -- Show seed for Default
	seedInput.Text = "" -- Reset seed
end

local function showSettingsPage()
	currentPage = "settings"
	titleLabel.Visible = true; titleShadow.Visible = true
	titleLabel.Text = "Settings"; titleShadow.Text = "Settings"
	scrollFrame.Visible = false; createPage.Visible = false; settingsPage.Visible = true
	emptyStateLabel.Visible = false
	btnRow1.Visible = false; btnRow2.Visible = false; createBtnBar.Visible = false; settingsBtnBar.Visible = true
	-- Sync settings page rows with current values
	settingsSeasonRow:SetValue(selectedSeason)
	settingsWeatherRow:SetValue(selectedWeather)
end

function updateMegaPlotSection()
	local isMega = (selectedMode == "MegaPlot")
	worldSection.Visible = isMega
	individualLabel.Visible = not isMega

	-- Show/hide mega-only buttons
	playWorldBtn:SetEnabled(false)
	saveBtn:SetEnabled(false)
	deleteBtn:SetEnabled(false)
	regenBtn:SetEnabled(isMega)

	if isMega then
		createNewBtn:SetText("Create New World")
		updateButtonStates()
	else
		createNewBtn:SetText("Apply Settings")
		selectedSlotIndex = nil
	end
end

-- ============================================
-- SLOT DATA REFRESH
-- ============================================
function refreshSlotData()
	if not GetMegaPlotSlots then GetMegaPlotSlots = Remotes:FindFirstChild("GetMegaPlotSlots") end
	if GetMegaPlotSlots then
		local success, data = pcall(function() return GetMegaPlotSlots:InvokeServer() end)
		if success and data then megaPlotSlots = data end
	end

	local anyHasData = false

	-- Collect saved timestamps for sorting (most recent first)
	local slotTimestamps = {}
	for i = 1, MAX_FREE_SLOTS do
		local slotInfo = megaPlotSlots[i]
		local isPending = (pendingWorldSlot == i and pendingWorldInfo ~= nil)
		if (slotInfo and slotInfo.hasData) or isPending then
			slotTimestamps[i] = (slotInfo and slotInfo.savedAt) or os.time()
		else
			slotTimestamps[i] = 0
		end
	end

	-- Build sorted order: slots with higher timestamps get lower LayoutOrder (appear first)
	local sortedSlots = {}
	for i = 1, MAX_FREE_SLOTS do table.insert(sortedSlots, i) end
	table.sort(sortedSlots, function(a, b) return slotTimestamps[a] > slotTimestamps[b] end)

	for rank, slotNum in ipairs(sortedSlots) do
		local entry = worldEntries[slotNum]
		if not entry then continue end

		local slotInfo = megaPlotSlots[slotNum]
		local isPending = (pendingWorldSlot == slotNum and pendingWorldInfo ~= nil)

		-- If the server now has data for this slot, clear pending
		if isPending and slotInfo and slotInfo.hasData then
			pendingWorldSlot = nil
			pendingWorldInfo = nil
			isPending = false
		end

		if slotInfo and slotInfo.hasData then
			anyHasData = true
			entry.frame.Visible = true
			entry.frame.LayoutOrder = 10 + rank -- sorted by recency

			local name = slotInfo.name or ("World " .. slotNum)
			local biome = slotInfo.biome or "Plains"
			local terrain = slotInfo.terrainStyle or "Default"
			local blockCount = slotInfo.blockCount or 0
			local savedAt = slotInfo.savedAt

			entry.nameLabel.Text = name
			entry.nameLabel.TextColor3 = MC.White

			-- Info line
			local biomeDisplay = BIOME_DISPLAY[biome] or biome
			local terrainDisplay = TERRAIN_DISPLAY[terrain] or terrain
			local blocksStr = blockCount >= 1000 and string.format("%.1fk", blockCount / 1000) or tostring(blockCount)
			entry.infoLabel.Text = biomeDisplay .. " • " .. terrainDisplay .. " • " .. blocksStr .. " blocks"

			-- Date
			if savedAt then
				local diff = os.time() - savedAt
				local timeStr
				if diff < 60 then timeStr = "just now"
				elseif diff < 3600 then timeStr = math.floor(diff / 60) .. "m ago"
				elseif diff < 86400 then timeStr = math.floor(diff / 3600) .. "h ago"
				else timeStr = math.floor(diff / 86400) .. "d ago" end
				entry.dateLabel.Text = "Saved " .. timeStr
			else
				entry.dateLabel.Text = ""
			end

			-- Thumbnail color
			local biomeColor = BiomeColors[biome] or MC.SlotEmpty
			entry.thumb.BackgroundColor3 = biomeColor
			entry.thumbText.Text = string.sub(biomeDisplay, 1, 1)

		elseif isPending then
			-- Show pending world immediately (save still in progress)
			anyHasData = true
			entry.frame.Visible = true
			entry.frame.LayoutOrder = 10 + rank

			local pInfo = pendingWorldInfo
			entry.nameLabel.Text = pInfo.name or "My World"
			entry.nameLabel.TextColor3 = MC.White

			local biomeDisplay = BIOME_DISPLAY[pInfo.biome] or pInfo.biome or "Plains"
			local terrainDisplay = TERRAIN_DISPLAY[pInfo.terrainStyle] or pInfo.terrainStyle or "Default"
			entry.infoLabel.Text = biomeDisplay .. " • " .. terrainDisplay
			entry.dateLabel.Text = "Saving..."

			local biomeColor = BiomeColors[pInfo.biome] or MC.SlotEmpty
			entry.thumb.BackgroundColor3 = biomeColor
			entry.thumbText.Text = string.sub(biomeDisplay, 1, 1)
		else
			-- Hide empty slots entirely
			entry.frame.Visible = false
		end
	end

	-- Show/hide empty state (only on main page in mega-plot mode)
	emptyStateLabel.Visible = (not anyHasData) and (currentPage == "main") and (selectedMode == "MegaPlot")

	-- If selected slot was deleted/hidden, deselect
	if selectedSlotIndex then
		local slotInfo = megaPlotSlots[selectedSlotIndex]
		local isPending = (pendingWorldSlot == selectedSlotIndex and pendingWorldInfo ~= nil)
		if (not slotInfo or not slotInfo.hasData) and not isPending then
			selectedSlotIndex = nil
		end
	end

	updateButtonStates()
end

-- ============================================
-- BUTTON CONNECTIONS
-- ============================================

-- Play Selected World
playWorldBtn.Button.MouseButton1Click:Connect(function()
	if not playWorldBtn:IsEnabled() then return end
	if not selectedSlotIndex then return end
	local slotInfo = megaPlotSlots[selectedSlotIndex]
	if not slotInfo or not slotInfo.hasData then return end

	local worldName = slotInfo.name or ("World " .. selectedSlotIndex)
	print("[PrivateServerSettingsUI] Loading world from slot", selectedSlotIndex, "(", worldName, ")")

	-- Close UI and start the game
	closeUI()
	startGame()

	-- Show loading screen IMMEDIATELY (don't wait for server round-trip)
	-- waitForReset=true because TerrainReady is still true from current world
	if _G.MegaPlotLoadingScreen and _G.MegaPlotLoadingScreen.Show then
		_G.MegaPlotLoadingScreen.Show("Loading " .. worldName .. "...", true)
	end

	-- Fire load request to server
	if not LoadMegaPlotFromSlot then LoadMegaPlotFromSlot = Remotes:FindFirstChild("LoadMegaPlotFromSlot") end
	if LoadMegaPlotFromSlot then LoadMegaPlotFromSlot:FireServer(selectedSlotIndex) end
end)

-- Create New World / Apply Settings
createNewBtn.Button.MouseButton1Click:Connect(function()
	if selectedMode == "MegaPlot" then
		createPageFromTitle = false
		showCreateNewPage()
	else
		-- Check if mode is changing (e.g. MegaPlot -> Individual)
		if selectedMode ~= initialMode then
			-- Mode change requires confirmation since it resets all blocks
			confirmText.Text = "Switch to Individual Plots? All mega plot blocks will be cleared!"
			confirmYes:SetText("Switch Mode")
			confirmAction = "modeChange"
			showConfirm()
		else
			-- No mode change, just apply settings
			ApplyPrivateServerSettings:FireServer({
				mode = selectedMode,
				biome = selectedBiome,
				terrainStyle = selectedTerrainStyle,
				season = selectedSeason,
				weather = selectedWeather,
			})
			initialMode = selectedMode
			closeUI()
			startGame()
		end
	end
end)

-- Save to selected slot (or next available)
saveBtn.Button.MouseButton1Click:Connect(function()
	if not saveBtn:IsEnabled() then return end

	-- If a world is selected, save/overwrite to that slot
	if selectedSlotIndex then
		local slotInfo = megaPlotSlots[selectedSlotIndex]
		if slotInfo and slotInfo.hasData then
			confirmText.Text = 'Overwrite "' .. (slotInfo.name or "World " .. selectedSlotIndex) .. '"? The existing save will be replaced.'
			confirmYes:SetText("Overwrite")
			confirmAction = "save_overwrite"
			showConfirm()
		else
			if not SaveMegaPlotToSlot then SaveMegaPlotToSlot = Remotes:FindFirstChild("SaveMegaPlotToSlot") end
			if SaveMegaPlotToSlot then SaveMegaPlotToSlot:FireServer(selectedSlotIndex) end
		end
	else
		-- No selection: find next empty slot
		local targetSlot = nil
		for i = 1, MAX_FREE_SLOTS do
			local si = megaPlotSlots[i]
			if not si or not si.hasData then
				targetSlot = i; break
			end
		end
		if targetSlot then
			if not SaveMegaPlotToSlot then SaveMegaPlotToSlot = Remotes:FindFirstChild("SaveMegaPlotToSlot") end
			if SaveMegaPlotToSlot then SaveMegaPlotToSlot:FireServer(targetSlot) end
		else
			showToast("All save slots are full! Delete a world first.", true)
		end
	end
end)

-- Regenerate
regenBtn.Button.MouseButton1Click:Connect(function()
	if not regenBtn:IsEnabled() then return end
	showRegenDialog()
end)

-- Delete
deleteBtn.Button.MouseButton1Click:Connect(function()
	if not deleteBtn:IsEnabled() then return end
	if not selectedSlotIndex then return end
	local slotInfo = megaPlotSlots[selectedSlotIndex]
	if not slotInfo or not slotInfo.hasData then return end

	confirmText.Text = "Delete save slot " .. selectedSlotIndex .. "? This cannot be undone!"
	confirmYes:SetText("Delete")
	confirmAction = "delete"
	showConfirm()
end)

-- Cancel
cancelBtn.Button.MouseButton1Click:Connect(function() closeUI() end)

-- Create page: Create & Play
createConfirmBtn.Button.MouseButton1Click:Connect(function()
	selectedMode = "MegaPlot"
	local worldName = nameInput.Text:gsub("^%s+", ""):gsub("%s+$", "")
	if worldName == "" then worldName = "My World" end

	-- Parse seed from input (nil if empty, otherwise numeric)
	local seedValue = nil
	if seedInput.Text ~= "" then
		seedValue = tonumber(seedInput.Text)
	end

	print("[PrivateServerSettingsUI] Creating new mega plot:", worldName, "terrain:", newTerrainStyle, "biome:", newBiome, "seed:", seedValue or "random")
	ApplyPrivateServerSettings:FireServer({
		mode = "MegaPlot",
		biome = newBiome,
		terrainStyle = newTerrainStyle,
		season = selectedSeason,
		weather = selectedWeather,
		confirmReset = "RESET",
		worldName = worldName,
		seed = seedValue,
	})
	initialMode = "MegaPlot"
	initialTerrainStyle = newTerrainStyle
	selectedTerrainStyle = newTerrainStyle
	selectedBiome = newBiome
	closeUI()
	startGame()

	-- Show loading screen IMMEDIATELY (don't wait for server round-trip)
	-- waitForReset=true in case TerrainReady is still true from a previous world
	if _G.MegaPlotLoadingScreen and _G.MegaPlotLoadingScreen.Show then
		_G.MegaPlotLoadingScreen.Show("Creating " .. worldName .. "...", true)
	end

	-- Find first empty slot immediately (for pending display)
	local pendingSlot = 1
	for i = 1, MAX_FREE_SLOTS do
		local si = megaPlotSlots[i]
		if not si or not si.hasData then
			pendingSlot = i; break
		end
	end

	-- Set pending world info so it shows immediately in the list
	pendingWorldSlot = pendingSlot
	pendingWorldInfo = {
		name = worldName,
		biome = newBiome,
		terrainStyle = newTerrainStyle,
	}

	-- Auto-save the newly created world to the first available slot
	task.spawn(function()
		-- Wait for terrain to actually finish generating
		print("[PrivateServerSettingsUI] Auto-save: waiting for terrain...")
		local terrainReadyValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainReady")
		if terrainReadyValue then
			local maxWait = 60
			local waited = 0
			while not terrainReadyValue.Value and waited < maxWait do
				task.wait(1)
				waited = waited + 1
			end
			print("[PrivateServerSettingsUI] Auto-save: terrain ready after", waited, "seconds")
		else
			print("[PrivateServerSettingsUI] Auto-save: no terrain ready value, waiting 10s")
			task.wait(10)
		end
		-- Extra delay to let any in-progress auto-save finish
		task.wait(5)
		print("[PrivateServerSettingsUI] Auto-save: starting...")

		-- Ensure remotes are available
		if not SaveMegaPlotToSlot then
			SaveMegaPlotToSlot = Remotes:WaitForChild("SaveMegaPlotToSlot", 10)
		end
		if not GetMegaPlotSlots then
			GetMegaPlotSlots = Remotes:WaitForChild("GetMegaPlotSlots", 10)
		end

		if not SaveMegaPlotToSlot then
			warn("[PrivateServerSettingsUI] Auto-save failed: SaveMegaPlotToSlot remote not found")
			pendingWorldSlot = nil; pendingWorldInfo = nil
			return
		end

		-- Re-check for first empty slot (may have changed)
		local targetSlot = pendingSlot
		if GetMegaPlotSlots then
			local success, data = pcall(function() return GetMegaPlotSlots:InvokeServer() end)
			if success and data then
				for i = 1, MAX_FREE_SLOTS do
					local si = data[i]
					if not si or not si.hasData then
						targetSlot = i; break
					end
				end
			end
		end

		print("[PrivateServerSettingsUI] Auto-saving new world to slot", targetSlot, "name:", worldName)
		SaveMegaPlotToSlot:FireServer(targetSlot, worldName)

		-- Clear pending and refresh slot data after save completes
		-- (The save fires asynchronously, wait for the MegaPlotSlotResult)
		local resultEvent = Remotes:FindFirstChild("MegaPlotSlotResult")
		if resultEvent then
			local conn
			conn = resultEvent.OnClientEvent:Connect(function(action, success, msg)
				if action == "save" then
					conn:Disconnect()
					pendingWorldSlot = nil
					pendingWorldInfo = nil
					print("[PrivateServerSettingsUI] Auto-save complete, refreshing slot data")
					refreshSlotData()
				end
			end)
			-- Timeout: clear pending after 2 minutes if no result
			task.delay(120, function()
				if conn.Connected then
					conn:Disconnect()
					pendingWorldSlot = nil
					pendingWorldInfo = nil
				end
			end)
		else
			-- No result event, just wait a bit and clear
			task.wait(30)
			pendingWorldSlot = nil
			pendingWorldInfo = nil
		end
	end)
end)

-- Create page: Back
createBackBtn.Button.MouseButton1Click:Connect(function()
	if createPageFromTitle then
		createPageFromTitle = false
		closeUI()
	else
		showMainPage()
	end
end)

-- Settings page: Done
settingsDoneBtn.Button.MouseButton1Click:Connect(function() closeUI() end)

-- ============================================
-- OPEN / CLOSE
-- ============================================
function openUI(setupMode)
	isUIOpen = true
	isSetupMode = setupMode or false
	screenGui.Enabled = true
	initialMode = selectedMode
	initialTerrainStyle = selectedTerrainStyle
	selectedSlotIndex = nil

	hideConfirm()
	hideRegenDialog()
	showMainPage()

	-- Refresh slot data
	task.spawn(refreshSlotData)

	task.defer(function()
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end)
end

function closeUI()
	isUIOpen = false
	screenGui.Enabled = false
	hideConfirm()
	hideRegenDialog()
end

-- ESC to close / navigate back
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Escape and isUIOpen then
		if regenPanel.Visible then
			hideRegenDialog()
		elseif confirmPanel.Visible then
			confirmAction = nil; hideConfirm()
		elseif currentPage == "createNew" then
			showMainPage()
		elseif currentPage == "settings" then
			closeUI()
		else
			closeUI()
		end
	end
end)

-- Mouse unlock while open
RunService.RenderStepped:Connect(function()
	if isUIOpen then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end)

-- ============================================
-- PREMIUM STATE
-- ============================================
local function updatePremiumState()
	if hasPremium then
		seasonRow:SetEnabled(true); weatherRow:SetEnabled(true)
		settingsSeasonRow:SetEnabled(true); settingsWeatherRow:SetEnabled(true)
		premiumNote.Visible = false; createPremiumNote.Visible = false; settingsPremiumNote.Visible = false
	else
		seasonRow:SetLocked(); weatherRow:SetLocked()
		settingsSeasonRow:SetLocked(); settingsWeatherRow:SetLocked()
		premiumNote.Visible = true; createPremiumNote.Visible = true; settingsPremiumNote.Visible = true
	end
end
updatePremiumState()

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamePassId, wasPurchased)
	if gamePassId == PREMIUM_GAMEPASS_ID and wasPurchased then
		hasPremium = true; updatePremiumState()
	end
end)

-- ============================================
-- TOAST NOTIFICATION
-- ============================================
local toastLabel = Instance.new("TextLabel")
toastLabel.Name = "Toast"
toastLabel.Size = mobile and UDim2.new(0.9, 0, 0, 34) or UDim2.new(0, 400, 0, 34)
toastLabel.AnchorPoint = Vector2.new(0.5, 0)
toastLabel.Position = UDim2.new(0.5, 0, 0, SCROLL_TOP)
toastLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
toastLabel.BackgroundTransparency = 0.1
toastLabel.BorderSizePixel = 0; toastLabel.Text = ""; toastLabel.TextColor3 = MC.White
toastLabel.TextSize = 13; toastLabel.Font = Enum.Font.Arcade
toastLabel.TextWrapped = true; toastLabel.Visible = false; toastLabel.ZIndex = 20
toastLabel.Parent = mainPanel

local toastStroke = Instance.new("UIStroke"); toastStroke.Color = Color3.fromRGB(60, 60, 60); toastStroke.Thickness = 1; toastStroke.Parent = toastLabel
Instance.new("UICorner", toastLabel).CornerRadius = UDim.new(0, 4)

local activeToastTween = nil
local function showToast(message, isError)
	if activeToastTween then activeToastTween:Cancel() end
	toastLabel.Text = message
	toastLabel.TextColor3 = isError and Color3.fromRGB(255, 100, 100) or Color3.fromRGB(100, 255, 130)
	toastStroke.Color = isError and Color3.fromRGB(120, 40, 40) or Color3.fromRGB(40, 100, 50)
	toastLabel.BackgroundTransparency = 0.2; toastLabel.TextTransparency = 0
	toastLabel.Visible = true
	task.delay(2.5, function()
		activeToastTween = TweenService:Create(toastLabel, TweenInfo.new(0.5), {BackgroundTransparency = 1, TextTransparency = 1})
		activeToastTween:Play()
		activeToastTween.Completed:Connect(function() toastLabel.Visible = false end)
	end)
end

-- ============================================
-- SLOT RESULT LISTENER
-- ============================================
task.spawn(function()
	if not MegaPlotSlotResult then MegaPlotSlotResult = Remotes:WaitForChild("MegaPlotSlotResult", 10) end
	if MegaPlotSlotResult then
		MegaPlotSlotResult.OnClientEvent:Connect(function(action, success, message)
			print("[PrivateServerSettingsUI] Slot result:", action, success, message)
			if isUIOpen then showToast(message or (action .. (success and " succeeded" or " failed")), not success) end
			if success then task.delay(0.3, refreshSlotData) end
		end)
	end
end)

-- ============================================
-- EXPOSE VIA _G (for TitleScreen to call)
-- ============================================
_G.PrivateServerSettingsUI = {
	Open = openUI,
	OpenToCreate = function()
		createPageFromTitle = true
		openUI(false)
		task.defer(showCreateNewPage)
	end,
	OpenSettings = function()
		openUI(false)
		task.defer(showSettingsPage)
	end,
	Close = closeUI,
	IsOpen = function() return isUIOpen end,
}

print("[PrivateServerSettingsUI] Initialized - Minecraft Select World Style!")
