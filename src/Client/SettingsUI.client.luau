--[[
	SettingsUI
	Global settings panel - available on all servers for all players
	
	Private server owner: Season & Weather, Server Mode (Individual/Mega Plot)
	Everyone: Placeholder for future personal settings (keybinds, etc.)
	
	Opened from TitleScreen "Settings" button or in-game gear icon
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Detect private server and ownership (non-blocking so _G.SettingsUI is available quickly)
local isPrivateServer = false
local isServerOwner = false

local isPrivateServerValue = ReplicatedStorage:FindFirstChild("IsPrivateServer")
if not isPrivateServerValue then
	isPrivateServerValue = ReplicatedStorage:WaitForChild("IsPrivateServer", 5)
end
if isPrivateServerValue and isPrivateServerValue.Value then
	isPrivateServer = true
	local ownerIdValue = ReplicatedStorage:FindFirstChild("PrivateServerOwnerId")
	if not ownerIdValue then
		ownerIdValue = ReplicatedStorage:WaitForChild("PrivateServerOwnerId", 10)
	end
	if ownerIdValue then
		-- Check immediately first
		if ownerIdValue.Value ~= 0 then
			isServerOwner = ownerIdValue.Value == player.UserId
		else
			-- Owner not set yet (debug mode) - detect async and update later
			task.spawn(function()
				local maxWait = 15
				local waited = 0
				while ownerIdValue.Value == 0 and waited < maxWait do
					task.wait(0.5)
					waited = waited + 0.5
				end
				isServerOwner = ownerIdValue.Value == player.UserId
				if isServerOwner then
					-- Show owner-only sections that were hidden
					local settingsGui = playerGui:FindFirstChild("SettingsUI")
					if settingsGui then
						local mainPnl = settingsGui:FindFirstChild("MainPanel")
						if mainPnl then
							local scroll = mainPnl:FindFirstChild("SettingsScroll")
							if scroll then
								local envSec = scroll:FindFirstChild("EnvironmentSection")
								if envSec then envSec.Visible = true end
								local srvSec = scroll:FindFirstChild("ServerSection")
								if srvSec then srvSec.Visible = true end
							end
						end
					end
					print("[SettingsUI] Owner detected (late), showing owner controls")
				end
			end)
		end
	end
end

-- Load configs
local BetaConfig = nil
pcall(function()
	BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))
end)

local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not Remotes then Remotes = ReplicatedStorage:WaitForChild("Remotes", 10) end
local UpdateCosmetics = Remotes and Remotes:FindFirstChild("UpdateCosmetics")
local SetPrivateServerMode = Remotes and Remotes:FindFirstChild("SetPrivateServerMode")
local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")

-- ============================================
-- PREMIUM CHECK
-- ============================================
local PREMIUM_GAMEPASS_ID = 1676832631
local hasPremium = false

local function checkPremiumOwnership()
	if player.UserId == game.CreatorId then return true end
	if BetaConfig and BetaConfig.IS_BETA then return true end
	if PREMIUM_GAMEPASS_ID == 0 then return false end
	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, PREMIUM_GAMEPASS_ID)
	end)
	return success and owns
end

hasPremium = checkPremiumOwnership()

-- ============================================
-- CONSTANTS
-- ============================================
local WEATHERS = {"Clear", "Rain", "Snow", "Fog"}
local SEASONS = {"Spring", "Summer", "Autumn", "Winter"}

local mobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local CONTENT_MAX_WIDTH = 520
local TITLE_HEIGHT = mobile and 52 or 60
local BTN_HEIGHT = mobile and 32 or 36
local BOTTOM_AREA = BTN_HEIGHT + 20 -- 1 row + padding
local SCROLL_TOP = TITLE_HEIGHT + 4
local SCROLL_BOTTOM = BOTTOM_AREA + 4
local CONTENT_PADDING = mobile and 16 or 40

-- MC Color palette
local MC = {
	DarkBG = Color3.fromRGB(30, 28, 26),
	ButtonBG = Color3.fromRGB(110, 110, 110),
	ButtonHover = Color3.fromRGB(130, 130, 130),
	ButtonDisabled = Color3.fromRGB(60, 60, 60),
	White = Color3.fromRGB(255, 255, 255),
	Gray = Color3.fromRGB(160, 160, 160),
	DarkGray = Color3.fromRGB(80, 80, 80),
	Shadow = Color3.fromRGB(20, 20, 20),
	Green = Color3.fromRGB(90, 170, 50),
	GreenHover = Color3.fromRGB(110, 190, 70),
	Yellow = Color3.fromRGB(255, 255, 85),
}

-- ============================================
-- STATE
-- ============================================
local isUIOpen = false
local selectedWeather = "Clear"
local selectedSeason = "Summer"
local selectedMode = modeValue and modeValue.Value or "Individual"

-- Read current values from build area if available
local function readCurrentEnvironment()
	local megaPlotVisibility = _G.MegaPlotVisibility
	if megaPlotVisibility and megaPlotVisibility.GetMegaPlotBuildArea then
		local buildArea = megaPlotVisibility.GetMegaPlotBuildArea()
		if buildArea then
			selectedSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
			selectedWeather = buildArea:GetAttribute("CurrentWeather") or "Clear"
			return
		end
	end
	-- Try individual build areas
	local workspace = game.Workspace
	for _, child in workspace:GetChildren() do
		if child:GetAttribute("IsBuildArea") then
			selectedSeason = child:GetAttribute("CurrentSeason") or "Summer"
			selectedWeather = child:GetAttribute("CurrentWeather") or "Clear"
			return
		end
	end
end

local function fireInstantCosmetic()
	if not UpdateCosmetics then
		UpdateCosmetics = Remotes and Remotes:FindFirstChild("UpdateCosmetics")
	end
	if not UpdateCosmetics then return end
	UpdateCosmetics:FireServer({
		season = selectedSeason,
		weather = selectedWeather,
	})
end

-- ============================================
-- SCREEN GUI
-- ============================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SettingsUI"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 120
screenGui.IgnoreGuiInset = true
screenGui.Enabled = false
screenGui.Parent = playerGui

-- ============================================
-- MAIN PANEL
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

-- Title
local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT - 8)
titleLabel.Position = UDim2.new(0, 0, 0, 4)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Settings"
titleLabel.TextColor3 = MC.White; titleLabel.TextSize = mobile and 22 or 28
titleLabel.Font = Enum.Font.Arcade; titleLabel.ZIndex = 3
titleLabel.Parent = mainPanel

local titleShadow = titleLabel:Clone()
titleShadow.Name = "TitleShadow"
titleShadow.Position = UDim2.new(0, 2, 0, 6)
titleShadow.TextColor3 = MC.Shadow; titleShadow.ZIndex = 2
titleShadow.Parent = mainPanel

-- ============================================
-- MC-STYLE BUTTON FACTORY
-- ============================================
local function createMCButton(parent, text, size, position, layoutOrder, onClick)
	local container = Instance.new("Frame")
	container.Size = size or UDim2.new(1, 0, 0, BTN_HEIGHT)
	if position then container.Position = position end
	container.BackgroundTransparency = 1; container.ZIndex = 3
	if layoutOrder then container.LayoutOrder = layoutOrder end
	container.Parent = parent

	local btn = Instance.new("TextButton")
	btn.Name = "Button"
	btn.Size = UDim2.new(1, 0, 1, 0)
	btn.BackgroundColor3 = MC.ButtonBG; btn.BorderSizePixel = 0
	btn.Text = ""; btn.AutoButtonColor = false; btn.ZIndex = 3
	btn.Parent = container

	local topHighlight = Instance.new("Frame")
	topHighlight.Name = "TopHighlight"
	topHighlight.Size = UDim2.new(1, -4, 0, 2)
	topHighlight.Position = UDim2.new(0, 2, 0, 0)
	topHighlight.BackgroundColor3 = Color3.fromRGB(150, 150, 150)
	topHighlight.BorderSizePixel = 0; topHighlight.ZIndex = 4
	topHighlight.Parent = btn

	local botShadow = Instance.new("Frame")
	botShadow.Name = "BotShadow"
	botShadow.Size = UDim2.new(1, -4, 0, 2)
	botShadow.Position = UDim2.new(0, 2, 1, -2)
	botShadow.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	botShadow.BorderSizePixel = 0; botShadow.ZIndex = 4
	botShadow.Parent = btn

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = text; label.TextColor3 = MC.White
	label.TextSize = mobile and 14 or 16; label.Font = Enum.Font.Arcade
	label.ZIndex = 4
	label.Parent = btn

	local shadow = label:Clone()
	shadow.Name = "LabelShadow"
	shadow.Position = UDim2.new(0, 1, 0, 1)
	shadow.TextColor3 = MC.Shadow; shadow.ZIndex = 3
	shadow.Parent = btn

	local enabled = true

	btn.MouseEnter:Connect(function()
		if enabled then btn.BackgroundColor3 = MC.ButtonHover end
	end)
	btn.MouseLeave:Connect(function()
		if enabled then btn.BackgroundColor3 = MC.ButtonBG end
	end)
	if onClick then
		btn.MouseButton1Click:Connect(onClick)
	end

	local api = {
		Button = btn,
		Container = container,
	}
	function api:SetText(t)
		label.Text = t; shadow.Text = t
	end
	function api:SetEnabled(e)
		enabled = e
		btn.BackgroundColor3 = e and MC.ButtonBG or MC.ButtonDisabled
		label.TextColor3 = e and MC.White or MC.Gray
		shadow.TextColor3 = e and MC.Shadow or MC.DarkGray
		topHighlight.Visible = e; botShadow.Visible = e
	end
	function api:IsEnabled() return enabled end
	function api:SetLocked()
		enabled = false
		btn.BackgroundColor3 = MC.ButtonDisabled
		label.TextColor3 = MC.Gray; shadow.TextColor3 = MC.DarkGray
		label.Text = "🔒 " .. text; shadow.Text = "🔒 " .. text
		topHighlight.Visible = false; botShadow.Visible = false
	end

	return api
end

-- ============================================
-- CYCLE ROW FACTORY
-- ============================================
local function createCycleRow(parent, label, options, displayMap, startValue, layoutOrder, onChanged)
	local index = 1
	for i, v in ipairs(options) do
		if v == startValue then index = i; break end
	end

	local function getDisplayText()
		local val = options[index]
		local display = displayMap and displayMap[val] or val
		return label .. ": " .. display
	end

	local mcBtn
	local locked = false

	local function cycle()
		if locked then return end
		index = index % #options + 1
		mcBtn:SetText(getDisplayText())
		if onChanged then onChanged(options[index]) end
	end

	mcBtn = createMCButton(parent, getDisplayText(), UDim2.new(1, 0, 0, BTN_HEIGHT), nil, layoutOrder, cycle)

	local rowApi = {
		Row = mcBtn.Container,
	}
	function rowApi:SetValue(val)
		for i, v in ipairs(options) do
			if v == val then index = i; break end
		end
		mcBtn:SetText(getDisplayText())
	end
	function rowApi:SetEnabled(e)
		locked = not e
		mcBtn:SetEnabled(e)
	end
	function rowApi:SetLocked()
		locked = true
		mcBtn:SetLocked()
	end

	return rowApi
end

-- ============================================
-- HELPER: Section label
-- ============================================
local function createSectionLabel(parent, text, layoutOrder, color)
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1, 0, 0, 22)
	lbl.BackgroundTransparency = 1
	lbl.Text = text
	lbl.TextColor3 = color or MC.White
	lbl.TextSize = 14; lbl.Font = Enum.Font.Arcade
	lbl.LayoutOrder = layoutOrder; lbl.ZIndex = 3
	lbl.Parent = parent
	return lbl
end

local function createSeparator(parent, layoutOrder)
	local sep = Instance.new("Frame")
	sep.Size = UDim2.new(0.8, 0, 0, 1)
	sep.BackgroundColor3 = MC.DarkGray
	sep.BackgroundTransparency = 0.5
	sep.BorderSizePixel = 0
	sep.LayoutOrder = layoutOrder; sep.ZIndex = 3
	sep.Parent = parent
	return sep
end

-- ============================================
-- SCROLL CONTENT
-- ============================================
local scrollFrame = Instance.new("ScrollingFrame")
scrollFrame.Name = "SettingsScroll"
scrollFrame.AnchorPoint = Vector2.new(0.5, 0)
scrollFrame.Size = UDim2.new(1, -CONTENT_PADDING * 2, 1, -(SCROLL_TOP + SCROLL_BOTTOM))
scrollFrame.Position = UDim2.new(0.5, 0, 0, SCROLL_TOP)
scrollFrame.BackgroundTransparency = 1; scrollFrame.BorderSizePixel = 0
scrollFrame.ScrollBarThickness = 4; scrollFrame.ScrollBarImageColor3 = MC.Gray
scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y
scrollFrame.ZIndex = 3; scrollFrame.Parent = mainPanel

local scrollConstraint = Instance.new("UISizeConstraint")
scrollConstraint.MaxSize = Vector2.new(CONTENT_MAX_WIDTH, 99999)
scrollConstraint.Parent = scrollFrame

local contentLayout = Instance.new("UIListLayout")
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Padding = UDim.new(0, 4)
contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
contentLayout.Parent = scrollFrame

-- ============================================
-- ENVIRONMENT SECTION (Owner only on private servers)
-- ============================================
local envSection = Instance.new("Frame")
envSection.Name = "EnvironmentSection"
envSection.Size = UDim2.new(1, 0, 0, 0)
envSection.AutomaticSize = Enum.AutomaticSize.Y
envSection.BackgroundTransparency = 1
envSection.LayoutOrder = 1; envSection.ZIndex = 3
envSection.Visible = (isPrivateServer and isServerOwner)
envSection.Parent = scrollFrame

local envLayout = Instance.new("UIListLayout")
envLayout.SortOrder = Enum.SortOrder.LayoutOrder
envLayout.Padding = UDim.new(0, 4)
envLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
envLayout.Parent = envSection

createSectionLabel(envSection, "Environment", 1, MC.White)

local envRow = Instance.new("Frame")
envRow.Size = UDim2.new(1, 0, 0, BTN_HEIGHT)
envRow.BackgroundTransparency = 1
envRow.LayoutOrder = 2; envRow.ZIndex = 3; envRow.Parent = envSection

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
premiumNote.TextColor3 = MC.Gray; premiumNote.TextSize = 10; premiumNote.Font = Enum.Font.Gotham
premiumNote.LayoutOrder = 3; premiumNote.Visible = not hasPremium; premiumNote.ZIndex = 3
premiumNote.Parent = envSection

createSeparator(envSection, 4)

-- ============================================
-- SERVER MODE SECTION (Owner only on private servers)
-- ============================================
local serverSection = Instance.new("Frame")
serverSection.Name = "ServerSection"
serverSection.Size = UDim2.new(1, 0, 0, 0)
serverSection.AutomaticSize = Enum.AutomaticSize.Y
serverSection.BackgroundTransparency = 1
serverSection.LayoutOrder = 5; serverSection.ZIndex = 3
serverSection.Visible = (isPrivateServer and isServerOwner)
serverSection.Parent = scrollFrame

local serverLayout = Instance.new("UIListLayout")
serverLayout.SortOrder = Enum.SortOrder.LayoutOrder
serverLayout.Padding = UDim.new(0, 4)
serverLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
serverLayout.Parent = serverSection

createSectionLabel(serverSection, "Server", 1, MC.White)

-- Forward declare so callbacks can reference it
local updateModeConfirmButton

local MODES = {"Individual", "MegaPlot"}
local MODE_DISPLAY = {
	["Individual"] = "Individual Plots",
	["MegaPlot"] = "Mega Plot (Shared)",
}

local modeRow = createCycleRow(
	serverSection, "Mode", MODES, MODE_DISPLAY, selectedMode, 2,
	function(newMode)
		selectedMode = newMode
		updateModeConfirmButton()
	end
)

-- Confirm button for mode change
local modeConfirmBtn = createMCButton(serverSection, "Apply Mode Change", UDim2.new(1, 0, 0, BTN_HEIGHT), nil, 3)
modeConfirmBtn:SetEnabled(false)

-- Warning label
local modeWarning = Instance.new("TextLabel")
modeWarning.Size = UDim2.new(1, 0, 0, 28)
modeWarning.BackgroundTransparency = 1
modeWarning.Text = "⚠ Changing mode will reset all terrain!\nThis cannot be undone."
modeWarning.TextColor3 = Color3.fromRGB(255, 180, 60)
modeWarning.TextSize = 10; modeWarning.Font = Enum.Font.GothamMedium
modeWarning.TextWrapped = true; modeWarning.LayoutOrder = 4; modeWarning.ZIndex = 3
modeWarning.Visible = false
modeWarning.Parent = serverSection

-- Track if mode was changed from the original
local originalMode = selectedMode

updateModeConfirmButton = function()
	local changed = (selectedMode ~= originalMode)
	modeConfirmBtn:SetEnabled(changed)
	modeWarning.Visible = changed
end

-- Override the cycle callback to also update the confirm button
local oldModeRowSetValue = modeRow.SetValue
modeRow.SetValue = function(self, val)
	oldModeRowSetValue(self, val)
	selectedMode = val
	updateModeConfirmButton()
end

-- (updateModeConfirmButton is now called directly from the onChanged callback)

modeConfirmBtn.Button.MouseButton1Click:Connect(function()
	if selectedMode == originalMode then return end
	if not modeConfirmBtn:IsEnabled() then return end
	
	modeConfirmBtn:SetText("Applying...")
	modeConfirmBtn:SetEnabled(false)
	
	task.spawn(function()
		-- Lazy-load remote if needed
		if not SetPrivateServerMode then
			SetPrivateServerMode = Remotes and Remotes:FindFirstChild("SetPrivateServerMode")
		end
		if not SetPrivateServerMode then
			-- Wait for it (server creates it)
			local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
			if remotesFolder then
				SetPrivateServerMode = remotesFolder:WaitForChild("SetPrivateServerMode", 10)
			end
		end
		if not SetPrivateServerMode then
			modeConfirmBtn:SetText("Error: Remote not found")
			task.wait(2)
			modeConfirmBtn:SetText("Apply Mode Change")
			updateModeConfirmButton()
			return
		end
		
		local success, err = SetPrivateServerMode:InvokeServer(selectedMode, "RESET")
		if success then
			originalMode = selectedMode
			modeConfirmBtn:SetText("Mode Changed!")
			updateModeConfirmButton()
			task.wait(1.5)
			modeConfirmBtn:SetText("Apply Mode Change")
		else
			modeConfirmBtn:SetText(err or "Failed")
			task.wait(2)
			modeConfirmBtn:SetText("Apply Mode Change")
			updateModeConfirmButton()
		end
	end)
end)

createSeparator(serverSection, 10)

-- ============================================
-- PERSONAL SETTINGS SECTION (Everyone)
-- ============================================
local personalSection = Instance.new("Frame")
personalSection.Name = "PersonalSection"
personalSection.Size = UDim2.new(1, 0, 0, 0)
personalSection.AutomaticSize = Enum.AutomaticSize.Y
personalSection.BackgroundTransparency = 1
personalSection.LayoutOrder = 10; personalSection.ZIndex = 3
personalSection.Parent = scrollFrame

local personalLayout = Instance.new("UIListLayout")
personalLayout.SortOrder = Enum.SortOrder.LayoutOrder
personalLayout.Padding = UDim.new(0, 4)
personalLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
personalLayout.Parent = personalSection

local futureLabel = Instance.new("TextLabel")
futureLabel.Size = UDim2.new(1, 0, 0, 60)
futureLabel.BackgroundTransparency = 1
futureLabel.Text = "More settings coming soon!"
futureLabel.TextColor3 = MC.Gray
futureLabel.TextSize = 14; futureLabel.Font = Enum.Font.GothamMedium
futureLabel.LayoutOrder = 1; futureLabel.ZIndex = 3
futureLabel.Parent = personalSection

-- ============================================
-- BOTTOM BUTTON
-- ============================================
local btnBar = Instance.new("Frame")
btnBar.Name = "BtnBar"
btnBar.AnchorPoint = Vector2.new(0.5, 0)
btnBar.Size = UDim2.new(1, -CONTENT_PADDING * 2, 0, BTN_HEIGHT)
btnBar.Position = UDim2.new(0.5, 0, 1, -(BOTTOM_AREA))
btnBar.BackgroundTransparency = 1; btnBar.ZIndex = 3
btnBar.Parent = mainPanel

local btnBarConstraint = Instance.new("UISizeConstraint")
btnBarConstraint.MaxSize = Vector2.new(CONTENT_MAX_WIDTH, BTN_HEIGHT)
btnBarConstraint.Parent = btnBar

local doneBtn = createMCButton(btnBar, "Done", UDim2.new(1, 0, 1, 0), UDim2.new(0, 0, 0, 0))

-- ============================================
-- OPEN / CLOSE
-- ============================================
local function openUI()
	isUIOpen = true
	screenGui.Enabled = true

	-- Refresh section visibility (owner may have been detected late)
	local envSec = scrollFrame:FindFirstChild("EnvironmentSection")
	if envSec then envSec.Visible = (isPrivateServer and isServerOwner) end
	local srvSec = scrollFrame:FindFirstChild("ServerSection")
	if srvSec then srvSec.Visible = (isPrivateServer and isServerOwner) end
	
	-- Sync mode with current server value
	if modeValue then
		selectedMode = modeValue.Value
		originalMode = selectedMode
		modeRow:SetValue(selectedMode)
	end

	-- Read current environment values
	readCurrentEnvironment()
	seasonRow:SetValue(selectedSeason)
	weatherRow:SetValue(selectedWeather)

	local crosshairGui = playerGui:FindFirstChild("CrosshairGui")
	if crosshairGui then crosshairGui.Enabled = false end
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
end

-- Done button
doneBtn.Button.MouseButton1Click:Connect(function()
	closeUI()
end)

-- ESC to close
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.Escape and isUIOpen then
		closeUI()
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
		premiumNote.Visible = false
	else
		seasonRow:SetLocked(); weatherRow:SetLocked()
		premiumNote.Visible = true
	end
end
updatePremiumState()

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, gamePassId, wasPurchased)
	if gamePassId == PREMIUM_GAMEPASS_ID and wasPurchased then
		hasPremium = true; updatePremiumState()
	end
end)

-- ============================================
-- GLOBAL API
-- ============================================
_G.SettingsUI = {
	Open = openUI,
	Close = closeUI,
	IsOpen = function() return isUIOpen end,
}

print("[SettingsUI] Initialized - available for all players")
