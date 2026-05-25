--[[
	TitleScreen.client.luau
	Displays the main menu when players join the game
	Public servers: Creative, Survival (Coming Soon), Settings
	Private servers: Continue, Worlds (owner only), Settings
	
	Hides other UI elements until game starts
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Detect mobile
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Get changelog config
local ChangelogConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ChangelogConfig"))
local SplashTexts = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("SplashTexts"))
local CoinConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("CoinConfig"))

-- Pick a random splash text (once per game load)
local chosenSplash = SplashTexts[math.random(1, #SplashTexts)]

-- Configuration (Minecraft-style)
local COLORS = {
	-- Button colors (stone-like)
	buttonNormal = Color3.fromRGB(110, 110, 110),
	buttonHover = Color3.fromRGB(130, 130, 130),
	buttonDisabled = Color3.fromRGB(70, 70, 70),
	buttonHighlight = Color3.fromRGB(160, 160, 160), -- Top/left 3D border
	buttonShadow = Color3.fromRGB(55, 55, 55),      -- Bottom/right 3D border
	-- Text
	textNormal = Color3.fromRGB(255, 255, 255),
	textDisabled = Color3.fromRGB(100, 100, 100),
	textShadow = Color3.fromRGB(60, 60, 60),
	-- Accents
	accent = Color3.fromRGB(76, 175, 80),
	accentHover = Color3.fromRGB(100, 200, 100),
	comingSoon = Color3.fromRGB(255, 193, 7),
	-- Changelog
	changelogBg = Color3.fromRGB(24, 20, 20),
	changelogHeader = Color3.fromRGB(50, 42, 42),
	changelogItemBg = Color3.fromRGB(40, 36, 36),
	changelogSubtext = Color3.fromRGB(170, 170, 170),
	changelogHighlight = Color3.fromRGB(60, 54, 54),
	changelogShadow = Color3.fromRGB(14, 12, 12),
	-- Notes styles
	notesWarning = Color3.fromRGB(180, 140, 40),
	notesWarningBg = Color3.fromRGB(60, 50, 30),
	notesInfo = Color3.fromRGB(70, 140, 200),
	notesInfoBg = Color3.fromRGB(30, 45, 60),
	notesSuccess = Color3.fromRGB(80, 180, 100),
	notesSuccessBg = Color3.fromRGB(30, 55, 35),
	notesError = Color3.fromRGB(200, 80, 80),
	notesErrorBg = Color3.fromRGB(60, 30, 30),
}

local FONTS = {
	title = Enum.Font.Arcade,
	button = Enum.Font.Arcade,
	subtitle = Enum.Font.Arcade,
}

-- 3D border thickness for Minecraft-style buttons
local BORDER_SIZE = 3

-- Flags (must be declared before hideGameUIs so it can see them)
local settingsOpenedFromMenu = false -- Flag to prevent hideGameUIs from closing settings UI
local gameWasPlayed = false -- Set true once player enters a game session

-- List of UI elements to hide during title screen (exact names from the scripts)
local uisToHide = {
	"InventoryGui",            -- Hotbar and inventory
	"LikesLeaderboardGui",     -- Player list with likes
	"TipToastsGui",            -- Hints like "Press E to open inventory"
	"ChatMonitorUI",           -- Chat monitor (owner only)
	"NotificationReminderGui", -- Notification reminders
	"CrosshairGui",            -- Crosshair
	"FeedbackGui",             -- Feedback UI
	"BiomeSelectionUI",        -- Biome selection
	"SaveLoadUI",              -- Save/Load UI
	"ChangelogGui",            -- Changelog
	"UpdateNotificationGui",   -- Update notifications
	"CameraMobileGui",         -- Mobile camera toggle
	"AutoLoadNotification",    -- "Welcome back! Loaded X blocks" notification
	"MobileControlsGui",       -- Mobile controls (fly, camera, inventory buttons)
	"PlotSetupButton",          -- Old floating plot setup button (if it exists)
	"PrivateServerSettingsUI",  -- Plot settings panel
	"SettingsUI",               -- General settings panel
	"MainMenuButtonGui",        -- Return to menu button
	"CoinHUD",                  -- Coin balance display
	"HelpBookButtonGui",        -- Help Book HUD button (was RewardsBookButtonGui; renamed)
	"PlusButtonGui",            -- Roblox Plus HUD button
}

-- UIs that should be enabled when game starts (not all UIs should auto-enable)
local uisToEnable = {
	"InventoryGui",            -- Hotbar and inventory - YES
	"LikesLeaderboardGui",     -- Player list with likes - YES
	"TipToastsGui",            -- Hints - YES
	"CrosshairGui",            -- Crosshair - YES
	"ChatMonitorUI",           -- Chat monitor (owner only) - YES if exists
	"MobileControlsGui",       -- Mobile controls - YES
	"MainMenuButtonGui",       -- Return to menu button - YES
	"CoinHUD",                 -- Coin balance display - YES
	"HelpBookButtonGui",       -- Help Book HUD button - YES (was RewardsBookButtonGui)
	"PlusButtonGui",           -- Roblox Plus HUD button - YES
}

-- Function to hide game UIs
local function hideGameUIs()
	for _, uiName in ipairs(uisToHide) do
		-- Skip hiding settings UIs if intentionally opened from the menu
		if settingsOpenedFromMenu and (uiName == "PrivateServerSettingsUI" or uiName == "SettingsUI") then
			continue
		end
		local ui = playerGui:FindFirstChild(uiName)
		if ui then
			ui.Enabled = false
		end
	end
	
	-- Also hide Roblox's default leaderboard if visible
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)
end

-- Function to show game UIs when game starts
local function showGameUIs()
	-- Enable the core game UIs
	for _, uiName in ipairs(uisToEnable) do
		local ui = playerGui:FindFirstChild(uiName)
		if ui then
			ui.Enabled = true
		end
	end
	
	-- NOTE: We do NOT re-enable the default Roblox player list here
	-- because we use a custom LikesLeaderboard instead
	
	-- Also check for any UIs that might load late and enable them
	task.spawn(function()
		for i = 1, 10 do
			task.wait(0.3)
			for _, uiName in ipairs(uisToEnable) do
				local ui = playerGui:FindFirstChild(uiName)
				if ui and not ui.Enabled then
					ui.Enabled = true
				end
			end
		end
	end)
end

-- Create blur effect
local blurEffect = Instance.new("BlurEffect")
blurEffect.Name = "TitleScreenBlur"
blurEffect.Size = 0 -- Start at 0, will tween in
blurEffect.Parent = Lighting

-- Create the ScreenGui
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TitleScreen"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 100

-- Main background frame (fully transparent, just for organization)
local background = Instance.new("Frame")
background.Name = "Background"
background.Size = UDim2.new(1, 0, 1, 0)
background.Position = UDim2.new(0, 0, 0, 0)
background.BackgroundTransparency = 1 -- Fully transparent
background.BorderSizePixel = 0
background.Parent = screenGui

-- Title container
local titleContainer = Instance.new("Frame")
titleContainer.Name = "TitleContainer"
if IsMobile then
	titleContainer.Size = UDim2.new(1, 0, 0.2, 0)
	titleContainer.Position = UDim2.new(0, 0, 0.08, 0)
else
	titleContainer.Size = UDim2.new(1, 0, 0.25, 0)
	titleContainer.Position = UDim2.new(0, 0, 0.08, 0)
end
titleContainer.BackgroundTransparency = 1
titleContainer.Parent = background

-- Game title (Image)
local titleImage = Instance.new("ImageLabel")
titleImage.Name = "TitleImage"
if IsMobile then
	titleImage.Size = UDim2.new(0.8, 0, 1, 0)
	titleImage.Position = UDim2.new(0.1, 0, 0, 0)
else
	titleImage.Size = UDim2.new(0.6, 0, 1, 0)
	titleImage.Position = UDim2.new(0.2, 0, 0, 0)
end
titleImage.BackgroundTransparency = 1
titleImage.Image = "rbxassetid://138853494655194"
titleImage.ScaleType = Enum.ScaleType.Fit
titleImage.Parent = titleContainer

-- Splash text (like Minecraft!) - positioned to the right of the logo
local splashText = Instance.new("TextLabel")
splashText.Name = "SplashText"
if IsMobile then
	splashText.Size = UDim2.new(0, 250, 0, 60)
	splashText.Position = UDim2.new(0.75, 0, 0.75, 0)
else
	splashText.Size = UDim2.new(0, 350, 0, 80)
	splashText.Position = UDim2.new(0.72, 0, 0.65, 0)
end
splashText.AnchorPoint = Vector2.new(0.5, 0.5)
splashText.Rotation = -12 -- Slight tilt
splashText.BackgroundTransparency = 1
splashText.Text = chosenSplash
splashText.TextColor3 = Color3.fromRGB(255, 255, 0) -- Yellow like Minecraft
splashText.TextSize = IsMobile and 18 or 24
splashText.Font = Enum.Font.Arcade -- Retro arcade font!
splashText.TextScaled = false
splashText.TextWrapped = false -- Don't wrap - prevents jitter on scale
splashText.ClipsDescendants = false
splashText.Parent = titleContainer

-- Add stroke for visibility
local splashStroke = Instance.new("UIStroke")
splashStroke.Color = Color3.fromRGB(60, 60, 0)
splashStroke.Thickness = 2
splashStroke.Parent = splashText

-- Gentle floating animation using Position (pure GPU transform, always smooth)
local splashBasePos = splashText.Position
local floatConnection

task.spawn(function()
	task.wait(0.8) -- Wait for fade-in
	floatConnection = RunService.RenderStepped:Connect(function()
		local offsetY = math.sin(os.clock() * 1.8) * 8 -- slow gentle float
		splashText.Position = UDim2.new(
			splashBasePos.X.Scale, splashBasePos.X.Offset,
			splashBasePos.Y.Scale, splashBasePos.Y.Offset + offsetY
		)
	end)
end)

-- Button container - position differently on mobile
-- On mobile we run a TWO-COLUMN layout: this container is the LEFT column
-- (Creative / Shop / Community / Settings stack) and the Plus group is moved
-- into a separate right-hand column (see plusColumn below). On desktop this
-- stays a single centered stack with Plus inline.
local buttonContainer = Instance.new("Frame")
buttonContainer.Name = "ButtonContainer"
if IsMobile then
	-- Mobile: left column. Narrower than before and nudged left of center so the
	-- Plus column has room on the right. Y offset matches the Plus column (-42)
	-- so the Creative button's top lines up with the Roblox Plus button's top.
	buttonContainer.Size = UDim2.new(0, 210, 0, 260)
	buttonContainer.Position = UDim2.new(0.5, -224, 0.5, -42)
else
	-- Desktop: positioned to the left of the panels (which right-anchor at 80%)
	buttonContainer.Size = UDim2.new(0, 300, 0, 290)
	buttonContainer.Position = UDim2.new(0.8, -420, 0.5, -100)
	buttonContainer.AnchorPoint = Vector2.new(1, 0)
end
buttonContainer.BackgroundTransparency = 1
buttonContainer.Parent = background

local buttonLayout = Instance.new("UIListLayout")
buttonLayout.Padding = UDim.new(0, 15)
buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Top
buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
buttonLayout.Parent = buttonContainer

-- Helper: create a 3D Minecraft-style border on a frame/button
local function addMinecraftBorder(parent, highlightColor, shadowColor, thickness)
	local bs = thickness or BORDER_SIZE
	-- Top highlight
	local top = Instance.new("Frame")
	top.Name = "BorderTop"
	top.Size = UDim2.new(1, 0, 0, bs)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = highlightColor
	top.BorderSizePixel = 0
	top.ZIndex = parent.ZIndex + 1
	top.Parent = parent
	-- Left highlight
	local left = Instance.new("Frame")
	left.Name = "BorderLeft"
	left.Size = UDim2.new(0, bs, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = highlightColor
	left.BorderSizePixel = 0
	left.ZIndex = parent.ZIndex + 1
	left.Parent = parent
	-- Bottom shadow
	local bottom = Instance.new("Frame")
	bottom.Name = "BorderBottom"
	bottom.Size = UDim2.new(1, 0, 0, bs)
	bottom.Position = UDim2.new(0, 0, 1, -bs)
	bottom.BackgroundColor3 = shadowColor
	bottom.BorderSizePixel = 0
	bottom.ZIndex = parent.ZIndex + 1
	bottom.Parent = parent
	-- Right shadow
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

-- Lookup table for button hover data (Roblox Instances don't allow arbitrary properties)
local ButtonHoverData = {}

-- Helper function to create Minecraft-style menu buttons
local function createMenuButton(name: string, text: string, isDisabled: boolean, comingSoonText: string?)
	-- Outer container for the 3D button
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = UDim2.new(1, 0, 0, IsMobile and 48 or 55)
	button.BackgroundColor3 = isDisabled and COLORS.buttonDisabled or COLORS.buttonNormal
	button.BackgroundTransparency = 0
	button.BorderSizePixel = 0
	button.Font = FONTS.button
	button.Text = text
	button.TextColor3 = isDisabled and COLORS.textDisabled or COLORS.textNormal
	button.TextSize = IsMobile and 16 or 20
	button.AutoButtonColor = false
	
	-- NO rounded corners - blocky Minecraft style
	
	-- 3D border (highlight top/left, shadow bottom/right)
	local borderHighlight = isDisabled and Color3.fromRGB(95, 95, 95) or COLORS.buttonHighlight
	local borderShadow = isDisabled and Color3.fromRGB(35, 35, 35) or COLORS.buttonShadow
	local borders = addMinecraftBorder(button, borderHighlight, borderShadow)
	
	-- Text shadow + foreground (both as children so ZIndex works)
	-- Always create these so they can be updated later
	button.Text = ""
	
	local shadow = Instance.new("TextLabel")
	shadow.Name = "TextShadow"
	shadow.Size = UDim2.new(1, 0, 1, 0)
	shadow.Position = UDim2.new(0, 2, 0, 2)
	shadow.BackgroundTransparency = 1
	shadow.Text = text
	shadow.TextColor3 = Color3.fromRGB(20, 20, 20)
	shadow.TextSize = IsMobile and 16 or 20
	shadow.Font = FONTS.button
	shadow.ZIndex = button.ZIndex + 1
	shadow.Parent = button
	
	local foreground = Instance.new("TextLabel")
	foreground.Name = "TextForeground"
	foreground.Size = UDim2.new(1, 0, 1, 0)
	foreground.Position = UDim2.new(0, 0, 0, 0)
	foreground.BackgroundTransparency = 1
	foreground.Text = text
	foreground.TextColor3 = isDisabled and COLORS.textDisabled or COLORS.textNormal
	foreground.TextSize = IsMobile and 16 or 20
	foreground.Font = FONTS.button
	foreground.ZIndex = button.ZIndex + 2
	foreground.Parent = button
	
	-- Coming soon badge
	if comingSoonText then
		local badge = Instance.new("TextLabel")
		badge.Name = "ComingSoonBadge"
		badge.Size = UDim2.new(0, IsMobile and 90 or 110, 0, IsMobile and 18 or 22)
		badge.Position = UDim2.new(1, IsMobile and -95 or -115, 0.5, IsMobile and -9 or -11)
		badge.BackgroundColor3 = COLORS.comingSoon
		badge.BorderSizePixel = 0
		badge.Font = FONTS.button
		badge.Text = comingSoonText
		badge.TextColor3 = Color3.fromRGB(0, 0, 0)
		badge.TextSize = IsMobile and 10 or 12
		badge.ZIndex = button.ZIndex + 2
		badge.Parent = button
		
		-- Badge shadow
		local badgeShadow = Instance.new("TextLabel")
		badgeShadow.Name = "BadgeShadow"
		badgeShadow.Size = UDim2.new(1, 0, 1, 0)
		badgeShadow.Position = UDim2.new(0, 1, 0, 1)
		badgeShadow.BackgroundTransparency = 1
		badgeShadow.Text = comingSoonText
		badgeShadow.TextColor3 = Color3.fromRGB(120, 90, 0)
		badgeShadow.TextSize = IsMobile and 10 or 12
		badgeShadow.Font = FONTS.button
		badgeShadow.ZIndex = badge.ZIndex - 1
		badgeShadow.Parent = badge
	end
	
	-- Hover/Press effects (only for enabled buttons)
	-- Store connections so colored buttons can disconnect them
	local hoverConns = {}
	if not isDisabled then
		hoverConns.enter = button.MouseEnter:Connect(function()
			button.BackgroundColor3 = COLORS.buttonHover
			borders.top.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
			borders.left.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
		end)
		
		hoverConns.leave = button.MouseLeave:Connect(function()
			button.BackgroundColor3 = COLORS.buttonNormal
			borders.top.BackgroundColor3 = COLORS.buttonHighlight
			borders.left.BackgroundColor3 = COLORS.buttonHighlight
			borders.bottom.BackgroundColor3 = COLORS.buttonShadow
			borders.right.BackgroundColor3 = COLORS.buttonShadow
		end)
		
		hoverConns.down = button.MouseButton1Down:Connect(function()
			-- Invert borders for pressed look
			button.BackgroundColor3 = Color3.fromRGB(90, 90, 90)
			borders.top.BackgroundColor3 = COLORS.buttonShadow
			borders.left.BackgroundColor3 = COLORS.buttonShadow
			borders.bottom.BackgroundColor3 = COLORS.buttonHighlight
			borders.right.BackgroundColor3 = COLORS.buttonHighlight
		end)
		
		hoverConns.up = button.MouseButton1Up:Connect(function()
			button.BackgroundColor3 = COLORS.buttonHover
			borders.top.BackgroundColor3 = COLORS.buttonHighlight
			borders.left.BackgroundColor3 = COLORS.buttonHighlight
			borders.bottom.BackgroundColor3 = COLORS.buttonShadow
			borders.right.BackgroundColor3 = COLORS.buttonShadow
		end)
	end
	
	-- Store connections and borders in lookup table for color overrides
	ButtonHoverData[button] = { conns = hoverConns, borders = borders }
	
	return button
end

-- ===== PRIVATE SERVER DETECTION =====
local isPrivateServer = false
local isServerOwner = false
local isFirstTimeSetup = false
local hasAnyWorlds = false
local lastPlayedSlot = nil -- Slot number of last played world (for auto-load)
local lastPlayedSlotName = nil -- Name of the last played world
local isIndividualMode = false -- True when server is in Individual plot mode (no world management needed)

-- Check if any mega plot worlds are saved (reusable across mode switches)
local function checkForSavedWorlds()
	if isIndividualMode then
		return true -- Individual mode always counts as having worlds
	end
	local RemotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not RemotesFolder then RemotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10) end
	local GetMegaPlotSlots = RemotesFolder and RemotesFolder:FindFirstChild("GetMegaPlotSlots")
	if not GetMegaPlotSlots then
		GetMegaPlotSlots = RemotesFolder and RemotesFolder:WaitForChild("GetMegaPlotSlots", 10)
	end
	if GetMegaPlotSlots then
		local success, data = pcall(function()
			return GetMegaPlotSlots:InvokeServer()
		end)
		if success and data then
			-- Capture last played slot
			local lps = data.lastPlayedSlot
			if lps and data[lps] and data[lps].hasData then
				lastPlayedSlot = lps
				lastPlayedSlotName = data[lps].name or ("World " .. lps)
			else
				lastPlayedSlot = nil
				lastPlayedSlotName = nil
			end
			for i = 1, 3 do
				if data[i] and data[i].hasData then return true end
			end
		end
	end
	return false
end

local function detectPrivateServer()
	local isPrivateServerValue = ReplicatedStorage:FindFirstChild("IsPrivateServer")
	if not isPrivateServerValue then
		isPrivateServerValue = ReplicatedStorage:WaitForChild("IsPrivateServer", 5)
	end
	if isPrivateServerValue and isPrivateServerValue.Value then
		isPrivateServer = true
		
		-- Check if first-time setup
		local firstSetupValue = ReplicatedStorage:FindFirstChild("PrivateServerFirstSetup")
		if not firstSetupValue then
			firstSetupValue = ReplicatedStorage:WaitForChild("PrivateServerFirstSetup", 5)
		end
		if firstSetupValue then
			isFirstTimeSetup = firstSetupValue.Value
		end
		
		-- Check if owner
		local ownerIdValue = ReplicatedStorage:FindFirstChild("PrivateServerOwnerId")
		if not ownerIdValue then
			ownerIdValue = ReplicatedStorage:WaitForChild("PrivateServerOwnerId", 10)
		end
		if ownerIdValue then
			-- Wait for owner assignment (debug mode may assign late)
			if ownerIdValue.Value == 0 then
				local waited = 0
				while ownerIdValue.Value == 0 and waited < 15 do
					task.wait(0.5)
					waited = waited + 0.5
				end
			end
			isServerOwner = ownerIdValue.Value == player.UserId
		end
	end
end

-- Create the menu buttons
-- Resume button (hidden by default, shown when returning to menu mid-game)
local resumeButton = createMenuButton("ResumeButton", "Resume", false)
resumeButton.LayoutOrder = 1
resumeButton.Visible = false
resumeButton.Parent = buttonContainer

-- Green styling for resume button
-- Disconnect default grey hover handlers first
local resumeData = ButtonHoverData[resumeButton]
if resumeData then
	for _, conn in pairs(resumeData.conns) do conn:Disconnect() end
	resumeData.conns = {}
end
resumeButton.BackgroundColor3 = Color3.fromRGB(60, 130, 60)
local resumeBorders = resumeData and resumeData.borders
if resumeBorders then
	resumeBorders.top.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
	resumeBorders.left.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
	resumeBorders.bottom.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
	resumeBorders.right.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
end
resumeButton.MouseEnter:Connect(function()
	resumeButton.BackgroundColor3 = Color3.fromRGB(80, 150, 80)
	if resumeBorders then
		resumeBorders.top.BackgroundColor3 = Color3.fromRGB(120, 210, 120)
		resumeBorders.left.BackgroundColor3 = Color3.fromRGB(120, 210, 120)
	end
end)
resumeButton.MouseLeave:Connect(function()
	resumeButton.BackgroundColor3 = Color3.fromRGB(60, 130, 60)
	if resumeBorders then
		resumeBorders.top.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
		resumeBorders.left.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
		resumeBorders.bottom.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
		resumeBorders.right.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
	end
end)
resumeButton.MouseButton1Down:Connect(function()
	resumeButton.BackgroundColor3 = Color3.fromRGB(40, 100, 40)
	if resumeBorders then
		resumeBorders.top.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
		resumeBorders.left.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
		resumeBorders.bottom.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
		resumeBorders.right.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
	end
end)
resumeButton.MouseButton1Up:Connect(function()
	resumeButton.BackgroundColor3 = Color3.fromRGB(80, 150, 80)
	if resumeBorders then
		resumeBorders.top.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
		resumeBorders.left.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
		resumeBorders.bottom.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
		resumeBorders.right.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
	end
end)

local creativeButton = createMenuButton("CreativeButton", "Creative", false)
creativeButton.LayoutOrder = 2
creativeButton.Parent = buttonContainer

-- Green styling for creative/play button
local creativeData = ButtonHoverData[creativeButton]
if creativeData then
	for _, conn in pairs(creativeData.conns) do conn:Disconnect() end
	creativeData.conns = {}
end
creativeButton.BackgroundColor3 = Color3.fromRGB(60, 130, 60)
local creativeBorders = creativeData and creativeData.borders
if creativeBorders then
	creativeBorders.top.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
	creativeBorders.left.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
	creativeBorders.bottom.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
	creativeBorders.right.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
end
creativeButton.MouseEnter:Connect(function()
	creativeButton.BackgroundColor3 = Color3.fromRGB(80, 150, 80)
	if creativeBorders then
		creativeBorders.top.BackgroundColor3 = Color3.fromRGB(120, 210, 120)
		creativeBorders.left.BackgroundColor3 = Color3.fromRGB(120, 210, 120)
	end
end)
creativeButton.MouseLeave:Connect(function()
	creativeButton.BackgroundColor3 = Color3.fromRGB(60, 130, 60)
	if creativeBorders then
		creativeBorders.top.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
		creativeBorders.left.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
		creativeBorders.bottom.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
		creativeBorders.right.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
	end
end)
creativeButton.MouseButton1Down:Connect(function()
	creativeButton.BackgroundColor3 = Color3.fromRGB(40, 100, 40)
	if creativeBorders then
		creativeBorders.top.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
		creativeBorders.left.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
		creativeBorders.bottom.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
		creativeBorders.right.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
	end
end)
creativeButton.MouseButton1Up:Connect(function()
	creativeButton.BackgroundColor3 = Color3.fromRGB(80, 150, 80)
	if creativeBorders then
		creativeBorders.top.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
		creativeBorders.left.BackgroundColor3 = Color3.fromRGB(100, 190, 100)
		creativeBorders.bottom.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
		creativeBorders.right.BackgroundColor3 = Color3.fromRGB(30, 70, 30)
	end
end)

-- Shop button (gold styled)
local shopButton = createMenuButton("ShopButton", "Shop", false)
shopButton.LayoutOrder = 3
shopButton.Parent = buttonContainer

-- Gold styling for shop button
local shopData = ButtonHoverData[shopButton]
if shopData then
	for _, conn in pairs(shopData.conns) do conn:Disconnect() end
	shopData.conns = {}
end
shopButton.BackgroundColor3 = Color3.fromRGB(140, 110, 30)
local shopBorders = shopData and shopData.borders
if shopBorders then
	shopBorders.top.BackgroundColor3 = Color3.fromRGB(200, 170, 60)
	shopBorders.left.BackgroundColor3 = Color3.fromRGB(200, 170, 60)
	shopBorders.bottom.BackgroundColor3 = Color3.fromRGB(70, 55, 15)
	shopBorders.right.BackgroundColor3 = Color3.fromRGB(70, 55, 15)
end
shopButton.MouseEnter:Connect(function()
	shopButton.BackgroundColor3 = Color3.fromRGB(160, 130, 40)
	if shopBorders then
		shopBorders.top.BackgroundColor3 = Color3.fromRGB(220, 190, 80)
		shopBorders.left.BackgroundColor3 = Color3.fromRGB(220, 190, 80)
	end
end)
shopButton.MouseLeave:Connect(function()
	shopButton.BackgroundColor3 = Color3.fromRGB(140, 110, 30)
	if shopBorders then
		shopBorders.top.BackgroundColor3 = Color3.fromRGB(200, 170, 60)
		shopBorders.left.BackgroundColor3 = Color3.fromRGB(200, 170, 60)
		shopBorders.bottom.BackgroundColor3 = Color3.fromRGB(70, 55, 15)
		shopBorders.right.BackgroundColor3 = Color3.fromRGB(70, 55, 15)
	end
end)
shopButton.MouseButton1Down:Connect(function()
	shopButton.BackgroundColor3 = Color3.fromRGB(110, 85, 20)
	if shopBorders then
		shopBorders.top.BackgroundColor3 = Color3.fromRGB(70, 55, 15)
		shopBorders.left.BackgroundColor3 = Color3.fromRGB(70, 55, 15)
		shopBorders.bottom.BackgroundColor3 = Color3.fromRGB(200, 170, 60)
		shopBorders.right.BackgroundColor3 = Color3.fromRGB(200, 170, 60)
	end
end)
shopButton.MouseButton1Up:Connect(function()
	shopButton.BackgroundColor3 = Color3.fromRGB(160, 130, 40)
	if shopBorders then
		shopBorders.top.BackgroundColor3 = Color3.fromRGB(200, 170, 60)
		shopBorders.left.BackgroundColor3 = Color3.fromRGB(200, 170, 60)
		shopBorders.bottom.BackgroundColor3 = Color3.fromRGB(70, 55, 15)
		shopBorders.right.BackgroundColor3 = Color3.fromRGB(70, 55, 15)
	end
end)

-- Shop button click handler connected later (after hideTitleScreen is defined)

-- Survival/Coming Soon button — hidden by default, repurposed as "Worlds" in private servers
local survivalButton = createMenuButton("SurvivalButton", "", true, "Coming Soon")
survivalButton.LayoutOrder = 10 -- Push to bottom, out of sight
survivalButton.Visible = false
survivalButton.Parent = buttonContainer

-- Join Community button (blue, hidden if already in group)
local GROUP_ID = CoinConfig.CommunityGroupId
local GROUP_SHARE_URL = CoinConfig.CommunityGroupShareUrl
local JOIN_REWARD = CoinConfig.CommunityJoinReward

local joinGroupButton = createMenuButton("JoinGroupButton", "Join Community", false)
joinGroupButton.LayoutOrder = 4
joinGroupButton.Visible = false -- Hidden until group check confirms not a member
joinGroupButton.Parent = buttonContainer

-- Blue styling
local joinData = ButtonHoverData[joinGroupButton]
if joinData then
	for _, conn in pairs(joinData.conns) do conn:Disconnect() end
	joinData.conns = {}
end
joinGroupButton.BackgroundColor3 = Color3.fromRGB(70, 120, 190)
local joinBorders = joinData and joinData.borders
if joinBorders then
	joinBorders.top.BackgroundColor3 = Color3.fromRGB(110, 160, 220)
	joinBorders.left.BackgroundColor3 = Color3.fromRGB(110, 160, 220)
	joinBorders.bottom.BackgroundColor3 = Color3.fromRGB(35, 65, 110)
	joinBorders.right.BackgroundColor3 = Color3.fromRGB(35, 65, 110)
end
joinGroupButton.MouseEnter:Connect(function()
	joinGroupButton.BackgroundColor3 = Color3.fromRGB(90, 140, 210)
	if joinBorders then
		joinBorders.top.BackgroundColor3 = Color3.fromRGB(130, 180, 240)
		joinBorders.left.BackgroundColor3 = Color3.fromRGB(130, 180, 240)
	end
end)
joinGroupButton.MouseLeave:Connect(function()
	joinGroupButton.BackgroundColor3 = Color3.fromRGB(70, 120, 190)
	if joinBorders then
		joinBorders.top.BackgroundColor3 = Color3.fromRGB(110, 160, 220)
		joinBorders.left.BackgroundColor3 = Color3.fromRGB(110, 160, 220)
		joinBorders.bottom.BackgroundColor3 = Color3.fromRGB(35, 65, 110)
		joinBorders.right.BackgroundColor3 = Color3.fromRGB(35, 65, 110)
	end
end)
joinGroupButton.MouseButton1Down:Connect(function()
	joinGroupButton.BackgroundColor3 = Color3.fromRGB(50, 90, 150)
	if joinBorders then
		joinBorders.top.BackgroundColor3 = Color3.fromRGB(35, 65, 110)
		joinBorders.left.BackgroundColor3 = Color3.fromRGB(35, 65, 110)
		joinBorders.bottom.BackgroundColor3 = Color3.fromRGB(110, 160, 220)
		joinBorders.right.BackgroundColor3 = Color3.fromRGB(110, 160, 220)
	end
end)
joinGroupButton.MouseButton1Up:Connect(function()
	joinGroupButton.BackgroundColor3 = Color3.fromRGB(90, 140, 210)
	if joinBorders then
		joinBorders.top.BackgroundColor3 = Color3.fromRGB(110, 160, 220)
		joinBorders.left.BackgroundColor3 = Color3.fromRGB(110, 160, 220)
		joinBorders.bottom.BackgroundColor3 = Color3.fromRGB(35, 65, 110)
		joinBorders.right.BackgroundColor3 = Color3.fromRGB(35, 65, 110)
	end
end)

joinGroupButton.MouseButton1Click:Connect(function()
	-- Replaced text-only behavior with: open share URL + poll for membership + claim reward.
	-- See the polling task below.
	if _G.BuildBlox_StartCommunityJoinFlow then
		_G.BuildBlox_StartCommunityJoinFlow()
	end
end)

-- ============================================
-- ROBLOX PLUS BUTTON
-- Sits between Join Community and Settings. Sky-blue branded styling to
-- match the in-game PlusButton (top HUD) and PlusUI panel. Click hides the
-- title screen WITHOUT starting the game (same approach Shop uses) and
-- defers the actual modal open to PlusUI.OpenFromTitleScreen.
-- ============================================
local plusButton = createMenuButton("PlusButton", "Roblox Plus", false)

-- The Plus button sits ON TOP OF a perks backdrop card that previews what you
-- get by subscribing ("10% off shop items", "Free private servers", ...).
-- Both live in plusGroup, which occupies the LO5 slot so the card pushes
-- Settings down rather than overlapping it. When the player already has Plus,
-- the card and the deal badge hide and the group collapses to just the button.
local PLUS_BTN_H = IsMobile and 48 or 55
-- Card is tall enough for a header + three TWO-LINE perk rows (the 10%-off
-- lines are too long to sit on one line at this width).
local PLUS_CARD_H = IsMobile and 132 or 140
local PLUS_CARD_OVERLAP = 8  -- card tucks this far under the button's bottom edge

local plusGroup = Instance.new("Frame")
plusGroup.Name = "PlusGroup"
plusGroup.BackgroundTransparency = 1
plusGroup.Size = UDim2.new(1, 0, 0, PLUS_BTN_H + PLUS_CARD_H - PLUS_CARD_OVERLAP)
plusGroup.BorderSizePixel = 0
plusGroup.LayoutOrder = 5
plusGroup.Parent = buttonContainer

-- MOBILE: pull the Plus group out of the left-column UIListLayout and into its
-- own right-hand column, so it sits SIDE BY SIDE with the Creative/Shop stack
-- rather than stretching the column down the screen. Desktop keeps it inline
-- in the stack (LayoutOrder 5) exactly as before, so none of this runs there.
if IsMobile then
	-- Right column container. Same width as the left buttons; positioned just to
	-- the right of the left column (which is 210 wide, anchored at center-224).
	-- 24px gutter between the two columns.
	local plusColumn = Instance.new("Frame")
	plusColumn.Name = "PlusColumn"
	plusColumn.Size = UDim2.new(0, 210, 0, plusGroup.Size.Y.Offset)
	-- Y offset pushes the column down so the Plus BUTTON's top roughly lines up
	-- with Creative's top in the left stack (the group is taller than a single
	-- button because of the perks card, so it can't share the left column's -90).
	plusColumn.Position = UDim2.new(0.5, 14, 0.5, -42)
	plusColumn.BackgroundTransparency = 1
	plusColumn.BorderSizePixel = 0
	plusColumn:SetAttribute("KeepTransparent", true)
	plusColumn.Parent = background

	-- Reparent the group; it keeps Size width (1,0) so it fills the new column.
	-- Drop the LayoutOrder dependency (no UIListLayout in this column) and pin to top.
	plusGroup.Position = UDim2.new(0, 0, 0, 0)
	plusGroup.Parent = plusColumn

	-- Keep the column height in sync if the group collapses (player has Plus) or
	-- expands (perks card shown). applyPlusTitleState resizes plusGroup, so mirror it.
	plusGroup:GetPropertyChangedSignal("Size"):Connect(function()
		plusColumn.Size = UDim2.new(0, 210, 0, plusGroup.Size.Y.Offset)
	end)
end

-- Button on top. ZIndex 2 (Sibling behavior) lifts its whole subtree above the
-- card's subtree, so the button's bevels render over the card's tucked top edge.
plusButton.ZIndex = 2
plusButton.Size = UDim2.new(1, 0, 0, PLUS_BTN_H)
plusButton.Position = UDim2.new(0, 0, 0, 0)
plusButton.Parent = plusGroup

-- Perks backdrop card (ZIndex 1, behind/below the button). Darker blue than the
-- button so the button reads as raised on top of it. Gets the same raised
-- Minecraft bevel as the button (light top/left, dark bottom/right) so it
-- reads as a solid panel rather than a flat rectangle.
local plusPerksCard = Instance.new("Frame")
plusPerksCard.Name = "PlusPerksCard"
plusPerksCard.Size = UDim2.new(1, 0, 0, PLUS_CARD_H)
plusPerksCard.Position = UDim2.new(0, 0, 0, PLUS_BTN_H - PLUS_CARD_OVERLAP)
plusPerksCard.BackgroundColor3 = Color3.fromRGB(30, 82, 140)
plusPerksCard.BorderSizePixel = 0
plusPerksCard.ZIndex = 1
plusPerksCard.Parent = plusGroup
addMinecraftBorder(plusPerksCard, Color3.fromRGB(58, 120, 182), Color3.fromRGB(18, 52, 96), 3)

local plusPerksHeader = Instance.new("TextLabel")
plusPerksHeader.Name = "Header"
plusPerksHeader.BackgroundTransparency = 1
plusPerksHeader.Position = UDim2.new(0, 12, 0, PLUS_CARD_OVERLAP + 4)
plusPerksHeader.Size = UDim2.new(1, -20, 0, 14)
plusPerksHeader.Text = "INCLUDES"
plusPerksHeader.TextColor3 = Color3.fromRGB(150, 200, 240)
plusPerksHeader.Font = FONTS.button
plusPerksHeader.TextSize = IsMobile and 9 or 10
plusPerksHeader.TextXAlignment = Enum.TextXAlignment.Left
plusPerksHeader.ZIndex = 2
plusPerksHeader.Parent = plusPerksCard

-- Perk rows: gold check + white text (RichText colors the check inline).
local plusPerksList = {
	"10% off shop items",
	"Free private servers",
	"10% off Robux purchases in game",
}
local perkRowsTop = PLUS_CARD_OVERLAP + 4 + 16  -- just below the header
-- Each row gets two lines worth of height and wraps, so long perks like
-- "10% off Robux purchases in game" break onto a second line instead of
-- overflowing the card width. ROW_H is the full slot per perk (text + gap).
local PERK_ROW_H = IsMobile and 30 or 34
for i, perkText in ipairs(plusPerksList) do
	local row = Instance.new("TextLabel")
	row.Name = "Perk" .. i
	row.BackgroundTransparency = 1
	row.RichText = true
	row.TextWrapped = true
	row.Position = UDim2.new(0, 14, 0, perkRowsTop + (i - 1) * PERK_ROW_H)
	row.Size = UDim2.new(1, -22, 0, PERK_ROW_H - 2)
	row.Text = string.format("<font color=\"#F4C430\">-</font>  %s", perkText)
	row.TextColor3 = Color3.fromRGB(255, 255, 255)
	row.Font = FONTS.button
	row.TextSize = IsMobile and 12 or 13
	row.TextXAlignment = Enum.TextXAlignment.Left
	row.TextYAlignment = Enum.TextYAlignment.Top
	row.ZIndex = 2
	row.Parent = plusPerksCard
end

-- (No deal sticker on the button — the perks card below already states the
-- 10% offer plainly, so a badge on the button would be redundant clutter.)

-- Subscribers don't need the pitch: hide the card + badge and collapse the
-- group back to button height (so Settings sits snug beneath it again).
local function applyPlusTitleState(subscribed)
	plusPerksCard.Visible = not subscribed
	plusGroup.Size = UDim2.new(1, 0, 0,
		subscribed and PLUS_BTN_H or (PLUS_BTN_H + PLUS_CARD_H - PLUS_CARD_OVERLAP))
end

task.spawn(function()
	for _ = 1, 30 do
		if _G.PlusController then break end
		task.wait(0.2)
	end
	local function refresh()
		local subbed = _G.PlusController
			and _G.PlusController.IsSubscribed
			and _G.PlusController.IsSubscribed() or false
		applyPlusTitleState(subbed)
	end
	refresh()
	if _G.PlusController and _G.PlusController.OnChanged then
		_G.PlusController.OnChanged(refresh)
	end
end)

-- Sky-blue Plus brand styling. Mirrors the JoinGroup blue treatment so the
-- buttons feel like part of the same family, but in a slightly more saturated
-- cyan/sky-blue palette to differentiate it from the social CTA above.
local plusData = ButtonHoverData[plusButton]
if plusData then
	for _, conn in pairs(plusData.conns) do conn:Disconnect() end
	plusData.conns = {}
end
plusButton.BackgroundColor3 = Color3.fromRGB(48, 130, 200)
local plusBorders = plusData and plusData.borders
if plusBorders then
	plusBorders.top.BackgroundColor3 = Color3.fromRGB(100, 180, 240)
	plusBorders.left.BackgroundColor3 = Color3.fromRGB(100, 180, 240)
	plusBorders.bottom.BackgroundColor3 = Color3.fromRGB(24, 70, 120)
	plusBorders.right.BackgroundColor3 = Color3.fromRGB(24, 70, 120)
end
plusButton.MouseEnter:Connect(function()
	plusButton.BackgroundColor3 = Color3.fromRGB(70, 155, 220)
	if plusBorders then
		plusBorders.top.BackgroundColor3 = Color3.fromRGB(130, 200, 255)
		plusBorders.left.BackgroundColor3 = Color3.fromRGB(130, 200, 255)
	end
end)
plusButton.MouseLeave:Connect(function()
	plusButton.BackgroundColor3 = Color3.fromRGB(48, 130, 200)
	if plusBorders then
		plusBorders.top.BackgroundColor3 = Color3.fromRGB(100, 180, 240)
		plusBorders.left.BackgroundColor3 = Color3.fromRGB(100, 180, 240)
		plusBorders.bottom.BackgroundColor3 = Color3.fromRGB(24, 70, 120)
		plusBorders.right.BackgroundColor3 = Color3.fromRGB(24, 70, 120)
	end
end)
plusButton.MouseButton1Down:Connect(function()
	plusButton.BackgroundColor3 = Color3.fromRGB(32, 100, 165)
	if plusBorders then
		plusBorders.top.BackgroundColor3 = Color3.fromRGB(24, 70, 120)
		plusBorders.left.BackgroundColor3 = Color3.fromRGB(24, 70, 120)
		plusBorders.bottom.BackgroundColor3 = Color3.fromRGB(100, 180, 240)
		plusBorders.right.BackgroundColor3 = Color3.fromRGB(100, 180, 240)
	end
end)
plusButton.MouseButton1Up:Connect(function()
	plusButton.BackgroundColor3 = Color3.fromRGB(70, 155, 220)
	if plusBorders then
		plusBorders.top.BackgroundColor3 = Color3.fromRGB(100, 180, 240)
		plusBorders.left.BackgroundColor3 = Color3.fromRGB(100, 180, 240)
		plusBorders.bottom.BackgroundColor3 = Color3.fromRGB(24, 70, 120)
		plusBorders.right.BackgroundColor3 = Color3.fromRGB(24, 70, 120)
	end
end)

-- (Plus deal badge + perks backdrop card are built in the ROBLOX PLUS BUTTON
-- block above, alongside the subscribe-state toggle.)

-- Plus button click handler connected later (after hideTitleScreen is defined)

-- ============================================
-- COMMUNITY JOIN FLOW (open URL → poll → claim reward)
-- ============================================
-- We resolve the remotes lazily so this script doesn't error out on machines
-- where CoinService hasn't created them yet (race on first server boot).
local GroupService = game:GetService("GroupService")
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local ClaimCommunityReward = Remotes and Remotes:WaitForChild("ClaimCommunityReward", 10)
local CommunityRewardResult = Remotes and Remotes:WaitForChild("CommunityRewardResult", 10)

local pollActive = false  -- true while we're watching for a membership flip
local claimAttempted = false -- prevents double-claim within a session

local function setJoinButtonText(text)
	local fg = joinGroupButton:FindFirstChild("TextForeground")
	local sh = joinGroupButton:FindFirstChild("TextShadow")
	if fg then fg.Text = text end
	if sh then sh.Text = text end
end

local function hideJoinButton()
	joinGroupButton.Visible = false
	pollActive = false
end

-- Custom welcome toast — fires once on successful community-join reward claim.
-- Slides in from the top, holds, slides out. Cardboard/sky-blue theme to match BuildBlox.
local function showCommunityWelcomeToast(coinAmount)
	local gui = Instance.new("ScreenGui")
	gui.Name = "CommunityWelcomeToast"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 1000
	gui.Parent = playerGui

	-- Outer card (cardboard tone, beveled like the menu buttons)
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, -120) -- starts off-screen
	card.Size = UDim2.new(0, 420, 0, 110)
	card.BackgroundColor3 = Color3.fromRGB(70, 120, 190) -- blue (matches join button)
	card.BorderSizePixel = 0
	card.Parent = gui

	-- Beveled borders (top/left lighter, bottom/right darker) to match menu-button look
	local function makeBorder(name, size, pos, color)
		local b = Instance.new("Frame")
		b.Name = name
		b.Size = size
		b.Position = pos
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.Parent = card
		return b
	end
	makeBorder("BorderTop",    UDim2.new(1, 0, 0, 4), UDim2.new(0, 0, 0, 0),    Color3.fromRGB(110, 160, 220))
	makeBorder("BorderLeft",   UDim2.new(0, 4, 1, 0), UDim2.new(0, 0, 0, 0),    Color3.fromRGB(110, 160, 220))
	makeBorder("BorderBottom", UDim2.new(1, 0, 0, 4), UDim2.new(0, 0, 1, -4),   Color3.fromRGB(35, 65, 110))
	makeBorder("BorderRight",  UDim2.new(0, 4, 1, 0), UDim2.new(1, -4, 0, 0),   Color3.fromRGB(35, 65, 110))

	-- Title line: "Welcome to the Community!"
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 12, 0, 14)
	title.Size = UDim2.new(1, -24, 0, 32)
	title.Font = Enum.Font.Arcade
	title.Text = "Welcome to the Community!"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.Parent = card

	-- Title shadow for depth
	local titleShadow = title:Clone()
	titleShadow.Name = "TitleShadow"
	titleShadow.Position = UDim2.new(0, 14, 0, 16)
	titleShadow.TextColor3 = Color3.fromRGB(20, 40, 70)
	titleShadow.ZIndex = title.ZIndex - 1
	titleShadow.Parent = card
	title.ZIndex = 2

	-- Reward line: "+150 BloxCoins"
	local reward = Instance.new("TextLabel")
	reward.Name = "Reward"
	reward.BackgroundTransparency = 1
	reward.Position = UDim2.new(0, 12, 0, 56)
	reward.Size = UDim2.new(1, -24, 0, 42)
	reward.Font = Enum.Font.Arcade
	reward.Text = "+" .. tostring(coinAmount) .. " BloxCoins"
	reward.TextColor3 = Color3.fromRGB(255, 220, 90) -- gold
	reward.TextScaled = true
	reward.TextXAlignment = Enum.TextXAlignment.Center
	reward.ZIndex = 2
	reward.Parent = card

	local rewardShadow = reward:Clone()
	rewardShadow.Name = "RewardShadow"
	rewardShadow.Position = UDim2.new(0, 14, 0, 58)
	rewardShadow.TextColor3 = Color3.fromRGB(80, 50, 0)
	rewardShadow.ZIndex = 1
	rewardShadow.Parent = card

	-- Slide in → hold → slide out
	local slideInInfo = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local slideOutInfo = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	local slideIn = TweenService:Create(card, slideInInfo, { Position = UDim2.new(0.5, 0, 0, 40) })
	slideIn:Play()

	task.delay(4.5, function()
		if not gui.Parent then return end
		local slideOut = TweenService:Create(card, slideOutInfo, { Position = UDim2.new(0.5, 0, 0, -120) })
		slideOut:Play()
		slideOut.Completed:Wait()
		gui:Destroy()
	end)
end

-- Listen for the server's verdict on a claim attempt.
if CommunityRewardResult then
	CommunityRewardResult.OnClientEvent:Connect(function(success, reason, amount)
		if success then
			setJoinButtonText("+" .. tostring(amount or JOIN_REWARD) .. " Coins!")
			pollActive = false
			showCommunityWelcomeToast(amount or JOIN_REWARD)
			task.delay(3, hideJoinButton)
		elseif reason == "already_claimed" then
			-- They were already rewarded on a previous session
			hideJoinButton()
		elseif reason == "not_in_group" then
			-- Server says they're not in the group — client thought otherwise.
			-- Reset attempt flag so the next poll tick can retry.
			claimAttempted = false
		elseif reason == "not_ready" then
			-- Coin data still loading; allow retry
			claimAttempted = false
		else
			-- award_failed / check_failed — allow retry, surface a hint
			claimAttempted = false
			setJoinButtonText("Try Again")
			task.delay(3, function()
				if pollActive then setJoinButtonText("Waiting for join...") end
			end)
		end
	end)
end

local function startPolling()
	if pollActive then return end
	pollActive = true
	setJoinButtonText("Waiting for join...")

	task.spawn(function()
		while pollActive and joinGroupButton.Parent do
			task.wait(3)
			if not pollActive then break end

			local ok, isMember = pcall(function()
				return player:IsInGroup(GROUP_ID)
			end)
			if ok and isMember and not claimAttempted then
				claimAttempted = true
				setJoinButtonText("Claiming reward...")
				if ClaimCommunityReward then
					ClaimCommunityReward:FireServer()
				end
				-- The server will respond via CommunityRewardResult; if it says
				-- not_in_group we reset claimAttempted and the next tick retries.
			end
		end
	end)
end

_G.BuildBlox_StartCommunityJoinFlow = function()
	-- Prompt the in-game group join dialog (Roblox shipped this Dec 2025 as
	-- GroupService:PromptJoinAsync). The previous approaches (OpenBrowserWindow,
	-- SocialService:PromptGroupMembership) either require core-script capability
	-- or simply don't exist on the engine.
	--
	-- PromptJoinAsync yields, so it has to run in its own task. It returns an
	-- Enum.GroupMembershipStatus telling us exactly what happened, which lets us
	-- claim the reward immediately on success instead of falling back to polling.
	task.spawn(function()
		setJoinButtonText("Opening prompt...")

		local ok, result = pcall(function()
			return GroupService:PromptJoinAsync(GROUP_ID)
		end)

		if not ok then
			-- API call errored outright — fall back to the legacy "manual search" path
			-- so older clients (pre-Dec-2025 builds) still have a way through.
			warn("[TitleScreen] PromptJoinAsync failed:", result)
			setJoinButtonText("Search: BuildBlox")
			task.delay(4, function()
				if pollActive then
					setJoinButtonText("Waiting for join...")
				else
					setJoinButtonText("Join Community")
				end
			end)
			startPolling()
			return
		end

		if result == Enum.GroupMembershipStatus.Joined
			or result == Enum.GroupMembershipStatus.AlreadyMember then
			-- Claim immediately — PromptJoinAsync invalidates the local IsInGroup
			-- cache on the client that just joined, so the server-side recheck via
			-- GroupService:GetGroupsAsync (uncached) will see the fresh membership.
			setJoinButtonText("Claiming reward...")
			claimAttempted = true
			if ClaimCommunityReward then
				ClaimCommunityReward:FireServer()
			end
		elseif result == Enum.GroupMembershipStatus.JoinRequestPending then
			-- Manual-approval community — the join hasn't gone through yet.
			setJoinButtonText("Request sent!")
			task.delay(4, function()
				setJoinButtonText("Join Community")
			end)
		else
			-- Enum.GroupMembershipStatus.None: cancelled or ineligible.
			setJoinButtonText("Join Community")
		end
	end)
end

-- Check group membership once on load and decide whether to show the button.
-- If they're already a member, the server's claim handler will short-circuit
-- on "already_claimed" — but we still pre-fire the claim once so members who
-- joined the group before this update was shipped get their 150 coins on next login.
--
-- DEV OVERRIDE: keep the button visible for the developer for testing.
local DEV_USERNAMES = { ["JoseTwinkleToe"] = true }
local IS_DEV = DEV_USERNAMES[player.Name] == true

task.spawn(function()
	local ok, isMember = pcall(function()
		return player:IsInGroup(GROUP_ID)
	end)
	if not ok then return end

	if IS_DEV then
		-- Dev sees the button regardless of membership. Click still opens the URL
		-- (or no-ops on console) and starts polling; server handles already_claimed.
		joinGroupButton.Visible = true
		if isMember then
			setJoinButtonText("[DEV] Test Reward")
		end
		return
	end

	if isMember then
		-- Already a member — try a one-shot claim in case they haven't been rewarded yet.
		-- Server will silently respond "already_claimed" if they were, and grant coins if not.
		joinGroupButton.Visible = false
		if ClaimCommunityReward then
			ClaimCommunityReward:FireServer()
		end
	else
		joinGroupButton.Visible = true
	end
end)

local settingsButton = createMenuButton("SettingsButton", "Settings", false)
settingsButton.LayoutOrder = 6
settingsButton.Parent = buttonContainer

-- Mode toggle confirm button (hidden by default, appears after cycling mode)
local confirmModeButton = createMenuButton("ConfirmModeButton", "Confirm Switch", false)
confirmModeButton.LayoutOrder = 7
confirmModeButton.Visible = false
confirmModeButton.Parent = buttonContainer

-- Red styling for confirm button (destructive action)
-- Disconnect default grey hover handlers first
local confirmData = ButtonHoverData[confirmModeButton]
if confirmData then
	for _, conn in pairs(confirmData.conns) do conn:Disconnect() end
	confirmData.conns = {}
end
confirmModeButton.BackgroundColor3 = Color3.fromRGB(140, 50, 50)
local confirmBorders = confirmData and confirmData.borders
if confirmBorders then
	confirmBorders.top.BackgroundColor3 = Color3.fromRGB(190, 80, 80)
	confirmBorders.left.BackgroundColor3 = Color3.fromRGB(190, 80, 80)
	confirmBorders.bottom.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
	confirmBorders.right.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
end
confirmModeButton.MouseEnter:Connect(function()
	confirmModeButton.BackgroundColor3 = Color3.fromRGB(160, 60, 60)
	if confirmBorders then
		confirmBorders.top.BackgroundColor3 = Color3.fromRGB(210, 100, 100)
		confirmBorders.left.BackgroundColor3 = Color3.fromRGB(210, 100, 100)
	end
end)
confirmModeButton.MouseLeave:Connect(function()
	confirmModeButton.BackgroundColor3 = Color3.fromRGB(140, 50, 50)
	if confirmBorders then
		confirmBorders.top.BackgroundColor3 = Color3.fromRGB(190, 80, 80)
		confirmBorders.left.BackgroundColor3 = Color3.fromRGB(190, 80, 80)
		confirmBorders.bottom.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
		confirmBorders.right.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
	end
end)
confirmModeButton.MouseButton1Down:Connect(function()
	confirmModeButton.BackgroundColor3 = Color3.fromRGB(110, 35, 35)
	if confirmBorders then
		confirmBorders.top.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
		confirmBorders.left.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
		confirmBorders.bottom.BackgroundColor3 = Color3.fromRGB(190, 80, 80)
		confirmBorders.right.BackgroundColor3 = Color3.fromRGB(190, 80, 80)
	end
end)
confirmModeButton.MouseButton1Up:Connect(function()
	confirmModeButton.BackgroundColor3 = Color3.fromRGB(160, 60, 60)
	if confirmBorders then
		confirmBorders.top.BackgroundColor3 = Color3.fromRGB(190, 80, 80)
		confirmBorders.left.BackgroundColor3 = Color3.fromRGB(190, 80, 80)
		confirmBorders.bottom.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
		confirmBorders.right.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
	end
end)

-- Warning label for mode switch
local modeWarningLabel = Instance.new("TextLabel")
modeWarningLabel.Name = "ModeWarning"
modeWarningLabel.Size = UDim2.new(1, 0, 0, IsMobile and 24 or 28)
modeWarningLabel.BackgroundTransparency = 1
modeWarningLabel.Text = "This will reset all terrain!"
modeWarningLabel.TextColor3 = Color3.fromRGB(255, 180, 60)
modeWarningLabel.TextSize = IsMobile and 11 or 13
modeWarningLabel.Font = Enum.Font.Arcade
modeWarningLabel.LayoutOrder = 6
modeWarningLabel.Visible = false
modeWarningLabel.Parent = buttonContainer

local warningShadow = Instance.new("TextLabel")
warningShadow.Size = UDim2.new(1, 0, 1, 0)
warningShadow.Position = UDim2.new(0, 1, 0, 1)
warningShadow.BackgroundTransparency = 1
warningShadow.Text = "This will reset all terrain!"
warningShadow.TextColor3 = Color3.fromRGB(80, 55, 15)
warningShadow.TextSize = IsMobile and 11 or 13
warningShadow.Font = Enum.Font.Arcade
warningShadow.Parent = modeWarningLabel

-- Mode toggle state
local settingsIsModeCycle = false -- true when button is a mode toggle (server owner)
local pendingMode = nil -- the mode user wants to switch to
local modeToggleBusy = false -- prevent double-clicks during switch

local MODE_DISPLAY_NAMES = {
	["Individual"] = "Individual Plots",
	["MegaPlot"] = "Mega Plot",
}

local function getModeButtonText(mode)
	return "Mode: " .. (MODE_DISPLAY_NAMES[mode] or mode)
end

-- Must be declared before resetModeToggle which uses it
local function setButtonText(button, text)
	local fg = button:FindFirstChild("TextForeground")
	local sh = button:FindFirstChild("TextShadow")
	if fg then fg.Text = text end
	if sh then sh.Text = text end
end

local function resetModeToggle()
	pendingMode = nil
	confirmModeButton.Visible = false
	modeWarningLabel.Visible = false
	-- Update button text to show current mode
	local currentMode = isIndividualMode and "Individual" or "MegaPlot"
	setButtonText(settingsButton, getModeButtonText(currentMode))
end

-- Helper to enable a disabled button visually
local function enableButton(button)
	local data = ButtonHoverData[button]
	local borders = data and data.borders
	
	button.BackgroundColor3 = COLORS.buttonNormal
	if borders then
		borders.top.BackgroundColor3 = COLORS.buttonHighlight
		borders.left.BackgroundColor3 = COLORS.buttonHighlight
		borders.bottom.BackgroundColor3 = COLORS.buttonShadow
		borders.right.BackgroundColor3 = COLORS.buttonShadow
	end
	
	-- Disconnect old handlers and add new ones
	if data then
		for _, conn in pairs(data.conns) do conn:Disconnect() end
		data.conns = {}
		data.conns.enter = button.MouseEnter:Connect(function()
			button.BackgroundColor3 = COLORS.buttonHover
			if borders then
				borders.top.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
				borders.left.BackgroundColor3 = Color3.fromRGB(180, 180, 180)
			end
		end)
		data.conns.leave = button.MouseLeave:Connect(function()
			button.BackgroundColor3 = COLORS.buttonNormal
			if borders then
				borders.top.BackgroundColor3 = COLORS.buttonHighlight
				borders.left.BackgroundColor3 = COLORS.buttonHighlight
				borders.bottom.BackgroundColor3 = COLORS.buttonShadow
				borders.right.BackgroundColor3 = COLORS.buttonShadow
			end
		end)
		data.conns.down = button.MouseButton1Down:Connect(function()
			button.BackgroundColor3 = Color3.fromRGB(90, 90, 90)
			if borders then
				borders.top.BackgroundColor3 = COLORS.buttonShadow
				borders.left.BackgroundColor3 = COLORS.buttonShadow
				borders.bottom.BackgroundColor3 = COLORS.buttonHighlight
				borders.right.BackgroundColor3 = COLORS.buttonHighlight
			end
		end)
		data.conns.up = button.MouseButton1Up:Connect(function()
			button.BackgroundColor3 = COLORS.buttonHover
			if borders then
				borders.top.BackgroundColor3 = COLORS.buttonHighlight
				borders.left.BackgroundColor3 = COLORS.buttonHighlight
				borders.bottom.BackgroundColor3 = COLORS.buttonShadow
				borders.right.BackgroundColor3 = COLORS.buttonShadow
			end
		end)
	end
end

-- Run private server detection (in background so it doesn't block UI creation)
task.spawn(function()
	detectPrivateServer()
	
	-- Now update buttons based on detection
	if not isPrivateServer then
		-- Public server: hide Settings button (no server settings to configure)
		settingsButton.Visible = false
	end
	
	if isPrivateServer then
		print("[TitleScreen] Private server detected! Owner:", isServerOwner, "FirstTime:", isFirstTimeSetup)
		
		-- Detect the server mode (Individual vs MegaPlot)
		local modeVal = ReplicatedStorage:FindFirstChild("PrivateServerMode")
		local currentMode = modeVal and modeVal.Value or "Individual"
		isIndividualMode = (currentMode ~= "MegaPlot")
		
		if isServerOwner and isFirstTimeSetup and not isIndividualMode then
			-- First time setup in MegaPlot mode: show "Create World"
			setButtonText(creativeButton, "Create World")
			
			-- Hide survival button (not needed during first-time setup)
			survivalButton.Visible = false
			
			-- Listen for when setup completes
			local firstSetupValue = ReplicatedStorage:FindFirstChild("PrivateServerFirstSetup")
			if firstSetupValue then
				firstSetupValue.Changed:Connect(function(newVal)
					if not newVal then
						isFirstTimeSetup = false
						-- Re-detect mode (owner may have chosen Individual or MegaPlot)
						local updatedMode = ReplicatedStorage:FindFirstChild("PrivateServerMode")
						isIndividualMode = not updatedMode or updatedMode.Value ~= "MegaPlot"
						-- Check if worlds exist after setup
						hasAnyWorlds = checkForSavedWorlds()
						if isIndividualMode then
							-- Individual mode: just show Play, no Worlds button
							setButtonText(creativeButton, "Play")
							survivalButton.Visible = false
						else
							-- MegaPlot mode: show Continue/Create World + Worlds button
							setButtonText(creativeButton, hasAnyWorlds and "Continue" or "Create World")
							survivalButton.Visible = true
							setButtonText(survivalButton, "Worlds")
							local wBadge1 = survivalButton:FindFirstChild("ComingSoonBadge")
							if wBadge1 then wBadge1.Visible = false end
						end
					end
				end)
			end
		else
			-- Returning server: check if any worlds exist
			hasAnyWorlds = checkForSavedWorlds()
			if isIndividualMode then
				setButtonText(creativeButton, "Play")
			else
				setButtonText(creativeButton, hasAnyWorlds and "Continue" or "Create World")
			end
		end
		
		if isServerOwner then
			if isIndividualMode then
				-- Individual mode: no Worlds button needed
				survivalButton.Visible = false
			else
				-- MegaPlot mode: show Worlds button
				setButtonText(survivalButton, "Worlds")
				local badge = survivalButton:FindFirstChild("ComingSoonBadge")
				if badge then badge.Visible = false end
				local survFg = survivalButton:FindFirstChild("TextForeground")
				if survFg then survFg.TextColor3 = COLORS.textNormal end
				
				-- Enable the button visually and add hover effects
				enableButton(survivalButton)
			end
			
			-- Convert Settings button into mode toggle for server owner
			settingsIsModeCycle = true
			setButtonText(settingsButton, getModeButtonText(currentMode))
		else
			-- Non-owner
			if isFirstTimeSetup and not isIndividualMode then
				-- MegaPlot first-time: owner needs to configure, show waiting
				setButtonText(creativeButton, "Waiting for setup...")
				creativeButton.AutoButtonColor = false
				-- Listen for setup to complete
				local firstSetupValue = ReplicatedStorage:FindFirstChild("PrivateServerFirstSetup")
				if firstSetupValue then
					firstSetupValue.Changed:Connect(function(newVal)
						if not newVal then
							isFirstTimeSetup = false
							-- Re-detect mode
							local updatedMode = ReplicatedStorage:FindFirstChild("PrivateServerMode")
							isIndividualMode = not updatedMode or updatedMode.Value ~= "MegaPlot"
							setButtonText(creativeButton, isIndividualMode and "Play" or "Continue")
						end
					end)
				end
			elseif isIndividualMode then
				-- Individual mode: non-owners can just play directly
				setButtonText(creativeButton, "Play")
			end
			
			-- Non-owner: hide the settings/worlds buttons
			survivalButton.Visible = false
			settingsButton.Visible = false
		end
	end
end)

-- Listen for mode changes (e.g., owner switches mode in SettingsUI)
task.spawn(function()
	local modeVal = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	if modeVal then
		modeVal.Changed:Connect(function(newMode)
			print("[TitleScreen] Server mode changed to:", newMode)
			isIndividualMode = (newMode ~= "MegaPlot")
			
			if isIndividualMode then
				setButtonText(creativeButton, gameWasPlayed and "Resume" or "Play")
				survivalButton.Visible = false
			else
				-- Re-check for saved worlds when mode changes to MegaPlot
				hasAnyWorlds = checkForSavedWorlds()
				setButtonText(creativeButton, hasAnyWorlds and "Continue" or "Create World")
				-- Show Resume only if we have worlds and game was played
				if gameWasPlayed and hasAnyWorlds then
					resumeButton.Visible = true
					creativeButton.Visible = false
				else
					resumeButton.Visible = false
					creativeButton.Visible = true
				end
				if isServerOwner then
					survivalButton.Visible = true
					setButtonText(survivalButton, "Worlds")
					local wBadge2 = survivalButton:FindFirstChild("ComingSoonBadge")
					if wBadge2 then wBadge2.Visible = false end
					local survFg2 = survivalButton:FindFirstChild("TextForeground")
					if survFg2 then survFg2.TextColor3 = COLORS.textNormal end
					enableButton(survivalButton)
				end
			end
			
			-- Update mode toggle button text
			if settingsIsModeCycle then
				resetModeToggle()
			end
		end)
	end
end)

-- Version label at bottom
local versionLabel = Instance.new("TextLabel")
versionLabel.Name = "Version"
versionLabel.Size = UDim2.new(0, 200, 0, 30)
versionLabel.Position = UDim2.new(0, 10, 1, -40)
versionLabel.BackgroundTransparency = 1
versionLabel.Font = Enum.Font.Arcade
versionLabel.Text = (ChangelogConfig.VERSION_NAME or "v1.0.0") .. " Beta"
versionLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
versionLabel.TextSize = IsMobile and 16 or 20
versionLabel.TextXAlignment = Enum.TextXAlignment.Left
versionLabel.Parent = background

local versionStroke = Instance.new("UIStroke")
versionStroke.Color = Color3.fromRGB(0, 0, 0)
versionStroke.Thickness = 1
versionStroke.Parent = versionLabel

-- ===== CHANGELOG PANEL =====
-- Only show on desktop - mobile screens are too small
local changelogPanel, changelogInner, changelogHeader, versionBadge

if not IsMobile then
	changelogPanel = Instance.new("Frame")
	changelogPanel.Name = "ChangelogPanel"
	changelogPanel.Size = UDim2.new(0, 360, 0, 220)
	changelogPanel.Position = UDim2.new(0.8, 0, 0.5, -90)
	changelogPanel.AnchorPoint = Vector2.new(1, 0)
	
	-- Will be resized after carousel/notes are determined
	local baseChangelogHeight = 220
	changelogPanel.BackgroundColor3 = COLORS.changelogBg
	changelogPanel.BackgroundTransparency = 0.05
	changelogPanel.BorderSizePixel = 0
	changelogPanel.Parent = background

-- Minecraft 3D border on changelog
addMinecraftBorder(changelogPanel, COLORS.changelogHighlight, COLORS.changelogShadow, 2)

-- Inner content container with padding
local changelogInner = Instance.new("Frame")
changelogInner.Name = "Inner"
changelogInner.Size = UDim2.new(1, -12, 1, -12)
changelogInner.Position = UDim2.new(0, 6, 0, 6)
changelogInner.BackgroundTransparency = 1
changelogInner.Parent = changelogPanel
changelogInner:SetAttribute("KeepTransparent", true)

-- Use UIListLayout for vertical arrangement
local innerLayout = Instance.new("UIListLayout")
innerLayout.SortOrder = Enum.SortOrder.LayoutOrder
innerLayout.Padding = UDim.new(0, 6)
innerLayout.Parent = changelogInner

-- Changelog header
local changelogHeader = Instance.new("Frame")
changelogHeader.Name = "Header"
changelogHeader.Size = UDim2.new(1, 0, 0, 42)
changelogHeader.BackgroundColor3 = COLORS.changelogHeader
changelogHeader.BackgroundTransparency = 0
changelogHeader.BorderSizePixel = 0
changelogHeader.LayoutOrder = 1
changelogHeader.Parent = changelogInner

-- 3D border on header
addMinecraftBorder(changelogHeader, COLORS.changelogHighlight, COLORS.changelogShadow, 2)

-- Title
local changelogTitle = Instance.new("TextLabel")
changelogTitle.Name = "Title"
changelogTitle.Size = UDim2.new(1, -70, 1, 0)
changelogTitle.Position = UDim2.new(0, 10, 0, 0)
changelogTitle.BackgroundTransparency = 1
changelogTitle.Text = ChangelogConfig.TITLE or "What's New"
changelogTitle.TextColor3 = COLORS.textNormal
changelogTitle.TextSize = 18
changelogTitle.Font = Enum.Font.Arcade
changelogTitle.TextXAlignment = Enum.TextXAlignment.Left
changelogTitle.Parent = changelogHeader

-- Version badge (show only major.minor, e.g. v1.4)
local fullVersion = ChangelogConfig.VERSION_NAME or "v1.0.0"
local shortVersion = fullVersion:match("v?(%d+%.%d+)") -- Extract first two numbers
shortVersion = "v" .. (shortVersion or "1.0")

local versionBadge = Instance.new("TextLabel")
versionBadge.Name = "VersionBadge"
versionBadge.Size = UDim2.new(0, 56, 0, 22)
versionBadge.Position = UDim2.new(1, -64, 0.5, -11)
versionBadge.BackgroundColor3 = COLORS.accent
versionBadge.BackgroundTransparency = 0
versionBadge.Text = shortVersion
versionBadge.TextColor3 = COLORS.textNormal
versionBadge.TextSize = 12
versionBadge.Font = Enum.Font.Arcade
versionBadge.Parent = changelogHeader

-- 3D border on version badge
addMinecraftBorder(versionBadge, Color3.fromRGB(120, 220, 140), Color3.fromRGB(40, 100, 50), 2)

-- ===== IMAGE CAROUSEL (optional) =====
local hasImages = ChangelogConfig.IMAGES and #ChangelogConfig.IMAGES > 0
local carouselHeight = 0

if hasImages then
	carouselHeight = 250 -- Height of the carousel area
	local images = ChangelogConfig.IMAGES
	local currentImageIndex = 1
	
	local carouselFrame = Instance.new("Frame")
	carouselFrame.Name = "Carousel"
	carouselFrame.Size = UDim2.new(1, 0, 0, carouselHeight)
	carouselFrame.BackgroundTransparency = 1
	carouselFrame.BorderSizePixel = 0
	carouselFrame.LayoutOrder = 2
	carouselFrame.ClipsDescendants = true
	carouselFrame:SetAttribute("KeepTransparent", true)
	carouselFrame.Parent = changelogInner
	
	-- Image display area (leave room for caption + dots below)
	local imageContainer = Instance.new("Frame")
	imageContainer.Name = "ImageContainer"
	imageContainer.Size = UDim2.new(1, 12, 0, carouselHeight - 38) -- Full panel width (compensate inner padding)
	imageContainer.Position = UDim2.new(0, -6, 0, 0)
	imageContainer.BackgroundColor3 = COLORS.changelogItemBg
	imageContainer.BackgroundTransparency = 0.3
	imageContainer.BorderSizePixel = 0
	imageContainer.ClipsDescendants = true
	imageContainer:SetAttribute("TargetTransparency", 0.3)
	imageContainer.Parent = carouselFrame
	
	addMinecraftBorder(imageContainer, COLORS.changelogHighlight, COLORS.changelogShadow, 2)
	
	local currentImage = Instance.new("ImageLabel")
	currentImage.Name = "CurrentImage"
	currentImage.Size = UDim2.new(1, -4, 1, -4)
	currentImage.Position = UDim2.new(0, 2, 0, 2)
	currentImage.BackgroundTransparency = 1
	currentImage.Image = images[1].imageId or ""
	currentImage.ScaleType = Enum.ScaleType.Fit
	currentImage.Parent = imageContainer
	
	-- Caption below image (not overlaid)
	local captionLabel = Instance.new("TextLabel")
	captionLabel.Name = "Caption"
	captionLabel.Size = UDim2.new(1, 0, 0, 18)
	captionLabel.Position = UDim2.new(0, 0, 0, carouselHeight - 36)
	captionLabel.BackgroundTransparency = 1
	captionLabel.BorderSizePixel = 0
	captionLabel.Text = images[1].caption or ""
	captionLabel.TextColor3 = COLORS.changelogSubtext
	captionLabel.TextSize = 11
	captionLabel.Font = Enum.Font.Arcade
	captionLabel.TextXAlignment = Enum.TextXAlignment.Center
	captionLabel.Visible = (images[1].caption and images[1].caption ~= "")
	captionLabel.Parent = carouselFrame
	
	-- Navigation arrows (only if multiple images)
	if #images > 1 then
		local function createArrow(name, text, posX, anchorX)
			local arrow = Instance.new("TextButton")
			arrow.Name = name
			arrow.Size = UDim2.new(0, 20, 0, 30)
			arrow.Position = UDim2.new(posX, 0, 0.5, -15)
			arrow.AnchorPoint = Vector2.new(anchorX, 0)
			arrow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			arrow.BackgroundTransparency = 0.4
			arrow.BorderSizePixel = 0
			arrow.Text = text
			arrow.TextColor3 = COLORS.textNormal
			arrow.TextSize = 16
			arrow.Font = Enum.Font.Arcade
			arrow.AutoButtonColor = false
			arrow.ZIndex = 2
			arrow:SetAttribute("TargetTransparency", 0.4)
			arrow.Parent = imageContainer
			
			arrow.MouseEnter:Connect(function()
				TweenService:Create(arrow, TweenInfo.new(0.15), {
					BackgroundTransparency = 0.2
				}):Play()
			end)
			arrow.MouseLeave:Connect(function()
				TweenService:Create(arrow, TweenInfo.new(0.15), {
					BackgroundTransparency = 0.4
				}):Play()
			end)
			
			return arrow
		end
		
		local leftArrow = createArrow("LeftArrow", "<", 0, 0)
		local rightArrow = createArrow("RightArrow", ">", 1, 1)
		
		-- Dot indicators
		local dotsContainer = Instance.new("Frame")
		dotsContainer.Name = "Dots"
		dotsContainer.Size = UDim2.new(1, 0, 0, 16)
		dotsContainer.Position = UDim2.new(0, 0, 1, -18)
		dotsContainer.BackgroundTransparency = 1
		dotsContainer:SetAttribute("KeepTransparent", true)
		dotsContainer.Parent = carouselFrame
		
		local dotsLayout = Instance.new("UIListLayout")
		dotsLayout.FillDirection = Enum.FillDirection.Horizontal
		dotsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		dotsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		dotsLayout.Padding = UDim.new(0, 4)
		dotsLayout.Parent = dotsContainer
		
		local dots = {}
		for idx = 1, #images do
			local dot = Instance.new("Frame")
			dot.Name = "Dot" .. idx
			dot.Size = UDim2.new(0, 6, 0, 6)
			dot.BackgroundColor3 = idx == 1 and COLORS.accent or COLORS.changelogSubtext
			dot.BackgroundTransparency = idx == 1 and 0 or 0.5
			dot.BorderSizePixel = 0
			dot.LayoutOrder = idx
			dot.Parent = dotsContainer
			table.insert(dots, dot)
		end
		
		-- Update carousel display
		local function showImage(index)
			currentImageIndex = index
			local img = images[index]
			
			-- Fade transition
			TweenService:Create(currentImage, TweenInfo.new(0.15), {
				ImageTransparency = 1
			}):Play()
			
			task.delay(0.15, function()
				currentImage.Image = img.imageId or ""
				captionLabel.Text = img.caption or ""
				captionLabel.Visible = (img.caption and img.caption ~= "")
				
				TweenService:Create(currentImage, TweenInfo.new(0.15), {
					ImageTransparency = 0
				}):Play()
			end)
			
			-- Update dots
			for i, dot in ipairs(dots) do
				local isActive = (i == index)
				TweenService:Create(dot, TweenInfo.new(0.15), {
					BackgroundColor3 = isActive and COLORS.accent or COLORS.changelogSubtext,
					BackgroundTransparency = isActive and 0 or 0.5
				}):Play()
			end
		end
		
		leftArrow.MouseButton1Click:Connect(function()
			local newIndex = currentImageIndex - 1
			if newIndex < 1 then newIndex = #images end
			showImage(newIndex)
		end)
		
		rightArrow.MouseButton1Click:Connect(function()
			local newIndex = currentImageIndex + 1
			if newIndex > #images then newIndex = 1 end
			showImage(newIndex)
		end)
		
		-- Auto-cycle every 5 seconds
		task.spawn(function()
			while carouselFrame.Parent do
				task.wait(5)
				if carouselFrame.Parent and screenGui.Enabled then
					local newIndex = currentImageIndex + 1
					if newIndex > #images then newIndex = 1 end
					showImage(newIndex)
				end
			end
		end)
	end
end

-- Developer Notes section (if present)
local hasNotes = ChangelogConfig.NOTES and ChangelogConfig.NOTES ~= ""

if hasNotes then
	local notesStyle = ChangelogConfig.NOTES_STYLE or "info"
	local notesBorderColor, notesBgColor
	
	if notesStyle == "warning" then
		notesBorderColor = COLORS.notesWarning
		notesBgColor = COLORS.notesWarningBg
	elseif notesStyle == "success" then
		notesBorderColor = COLORS.notesSuccess
		notesBgColor = COLORS.notesSuccessBg
	elseif notesStyle == "error" then
		notesBorderColor = COLORS.notesError
		notesBgColor = COLORS.notesErrorBg
	else
		notesBorderColor = COLORS.notesInfo
		notesBgColor = COLORS.notesInfoBg
	end
	
	local notesFrame = Instance.new("Frame")
	notesFrame.Name = "Notes"
	notesFrame.Size = UDim2.new(1, 0, 0, IsMobile and 50 or 70)
	notesFrame.BackgroundColor3 = notesBgColor
	notesFrame.BackgroundTransparency = 0.2
	notesFrame.BorderSizePixel = 0
	notesFrame.LayoutOrder = 3
	notesFrame:SetAttribute("TargetTransparency", 0.2)
	notesFrame.Parent = changelogInner
	
	-- No rounded corners - Minecraft style
	
	-- Left accent bar
	local notesAccent = Instance.new("Frame")
	notesAccent.Name = "Accent"
	notesAccent.Size = UDim2.new(0, 3, 1, -6)
	notesAccent.Position = UDim2.new(0, 3, 0, 3)
	notesAccent.BackgroundColor3 = notesBorderColor
	notesAccent.BorderSizePixel = 0
	notesAccent:SetAttribute("TargetTransparency", 0)
	notesAccent.Parent = notesFrame
	
	-- No rounded corners on accent bar
	
	-- Notes text (scrollable)
	local notesScroll = Instance.new("ScrollingFrame")
	notesScroll.Name = "TextScroll"
	notesScroll.Size = UDim2.new(1, -16, 1, -8)
	notesScroll.Position = UDim2.new(0, 12, 0, 4)
	notesScroll.BackgroundTransparency = 1
	notesScroll.BorderSizePixel = 0
	notesScroll.ScrollBarThickness = 2
	notesScroll.ScrollBarImageColor3 = notesBorderColor
	notesScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	notesScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	notesScroll.Parent = notesFrame
	
	local notesText = Instance.new("TextLabel")
	notesText.Name = "Text"
	notesText.Size = UDim2.new(1, -4, 0, 0)
	notesText.BackgroundTransparency = 1
	notesText.Text = ChangelogConfig.NOTES
	notesText.TextColor3 = COLORS.textNormal
	notesText.TextSize = 10
	notesText.Font = Enum.Font.Arcade
	notesText.TextXAlignment = Enum.TextXAlignment.Left
	notesText.TextYAlignment = Enum.TextYAlignment.Top
	notesText.TextWrapped = true
	notesText.AutomaticSize = Enum.AutomaticSize.Y
	notesText.Parent = notesScroll
end

-- Calculate offsets for carousel and notes
local notesOffset = hasNotes and 76 or 0
local carouselOffset = carouselHeight > 0 and (carouselHeight + 6) or 0

-- Resize changelog panel to fit carousel + notes
local finalChangelogHeight = baseChangelogHeight + carouselOffset + notesOffset
changelogPanel.Size = UDim2.new(0, 360, 0, finalChangelogHeight)
-- Re-center vertically
-- Cap the panel height so it doesn't overflow above the logo
local maxChangelogHeight = 460
finalChangelogHeight = math.min(finalChangelogHeight, maxChangelogHeight)
changelogPanel.Size = UDim2.new(0, 360, 0, finalChangelogHeight)
changelogPanel.Position = UDim2.new(0.8, 0, 0.5, -finalChangelogHeight / 2 + 80)
changelogPanel.AnchorPoint = Vector2.new(1, 0)

-- Content area (scrolling frame for changes)
local changelogContent = Instance.new("ScrollingFrame")
changelogContent.Name = "Content"
-- Adjust height based on platform and whether notes exist
local contentHeight = -50 - notesOffset - carouselOffset
changelogContent.Size = UDim2.new(1, 0, 1, contentHeight)
changelogContent.BackgroundTransparency = 1
changelogContent.BorderSizePixel = 0
changelogContent.ScrollBarThickness = 3
changelogContent.ScrollBarImageColor3 = COLORS.accent
changelogContent.CanvasSize = UDim2.new(0, 0, 0, 0)
changelogContent.AutomaticCanvasSize = Enum.AutomaticSize.Y
changelogContent.LayoutOrder = 4
changelogContent.Parent = changelogInner

local contentLayout = Instance.new("UIListLayout")
contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout.Padding = UDim.new(0, 4)
contentLayout.Parent = changelogContent

-- Create change entries
for i, change in ipairs(ChangelogConfig.CHANGES or {}) do
	local changeText = change.text or ""
	
	local item = Instance.new("Frame")
	item.Name = "Item" .. i
	item.Size = UDim2.new(1, -6, 0, 0)
	item.BackgroundColor3 = COLORS.changelogItemBg
	item.BackgroundTransparency = 0.3
	item.BorderSizePixel = 0
	item.LayoutOrder = i
	item.AutomaticSize = Enum.AutomaticSize.Y
	item:SetAttribute("TargetTransparency", 0.3)
	item.Parent = changelogContent
	
	-- Bullet point
	local bullet = Instance.new("TextLabel")
	bullet.Name = "Bullet"
	bullet.Size = UDim2.new(0, 14, 0, 14)
	bullet.Position = UDim2.new(0, 6, 0, 5)
	bullet.BackgroundTransparency = 1
	bullet.Text = "•"
	bullet.TextSize = 16
	bullet.Font = Enum.Font.Arcade
	bullet.TextColor3 = COLORS.accent
	bullet.Parent = item
	
	-- Text label with auto-size
	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.Size = UDim2.new(1, -26, 0, 0)
	text.Position = UDim2.new(0, 20, 0, 5)
	text.BackgroundTransparency = 1
	text.Text = changeText
	text.TextColor3 = COLORS.textNormal
	text.TextSize = 13
	text.Font = Enum.Font.Arcade
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.TextWrapped = true
	text.AutomaticSize = Enum.AutomaticSize.Y
	text.Parent = item
	
	-- Add bottom padding via UIPadding
	local itemPadding = Instance.new("UIPadding")
	itemPadding.PaddingBottom = UDim.new(0, 5)
	itemPadding.Parent = item
end

-- Footer text
local changelogFooter = Instance.new("TextLabel")
changelogFooter.Name = "Footer"
changelogFooter.Size = UDim2.new(1, 0, 0, 20)
changelogFooter.BackgroundTransparency = 1
changelogFooter.Text = ChangelogConfig.FOOTER or ""
changelogFooter.TextColor3 = COLORS.changelogSubtext
changelogFooter.TextSize = 12
changelogFooter.Font = Enum.Font.Arcade
changelogFooter.TextXAlignment = Enum.TextXAlignment.Center
changelogFooter.LayoutOrder = 999
changelogFooter.Parent = changelogContent

	-- Mark changelog elements with their target transparencies
	changelogPanel:SetAttribute("TargetTransparency", 0.05)
	changelogHeader:SetAttribute("TargetTransparency", 0)
	versionBadge:SetAttribute("TargetTransparency", 0)
end -- End of if not IsMobile

-- Function to hide title screen with animation
local function hideTitleScreen()
	-- Mark that a game session has been active
	gameWasPlayed = true
	settingsOpenedFromMenu = false -- Reset so hideGameUIs works normally again
	
	-- Stop the float animation
	if floatConnection then
		floatConnection:Disconnect()
		floatConnection = nil
	end
	
	-- Fade out blur
	TweenService:Create(blurEffect, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = 0
	}):Play()
	
	-- Fade all children
	for _, child in background:GetDescendants() do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			TweenService:Create(child, TweenInfo.new(0.5), {
				TextTransparency = 1,
				BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("ImageLabel") then
			TweenService:Create(child, TweenInfo.new(0.5), {
				ImageTransparency = 1,
				BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("Frame") then
			TweenService:Create(child, TweenInfo.new(0.5), {
				BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("UIStroke") then
			TweenService:Create(child, TweenInfo.new(0.5), {
				Transparency = 1
			}):Play()
		end
	end
	
	task.wait(0.5)
	screenGui.Enabled = false
	
	-- Show game UIs after title screen is hidden
	showGameUIs()
end

-- Function to show title screen
local function showTitleScreen()
	screenGui.Enabled = true
	settingsOpenedFromMenu = false
	hideGameUIs()
	-- Close inventory after title screen is open (so crosshair stays hidden)
	if _G.InventoryController and _G.InventoryController.CloseInventory then
		_G.InventoryController.CloseInventory()
	end

	
	-- If a game session was active, show Resume and hide Continue/Create World
	if gameWasPlayed then
		resumeButton.Visible = true
		if not isPrivateServer then
			-- Public server: hide Creative since Resume does the same thing
			creativeButton.Visible = false
		elseif isPrivateServer then
			if not isIndividualMode then
				-- Re-check for saved worlds when returning to menu in MegaPlot mode
				hasAnyWorlds = checkForSavedWorlds()
				if hasAnyWorlds then
					creativeButton.Visible = false -- Hide Continue, Resume replaces it
				else
					-- No worlds yet - show Create World, hide Resume
					resumeButton.Visible = false
					creativeButton.Visible = true
					setButtonText(creativeButton, "Create World")
				end
			else
				creativeButton.Visible = false -- Individual mode: Resume replaces Play
			end
		end
		
		-- Show Worlds button when returning to menu in MegaPlot mode (owner only)
		if isPrivateServer and isServerOwner and not isIndividualMode then
			survivalButton.Visible = true
			setButtonText(survivalButton, "Worlds")
			local wBadge3 = survivalButton:FindFirstChild("ComingSoonBadge")
			if wBadge3 then wBadge3.Visible = false end
		else
			survivalButton.Visible = false
		end
	else
		resumeButton.Visible = false
		creativeButton.Visible = true
	end
	
	-- Reset mode toggle state when showing title screen
	if settingsIsModeCycle then
		resetModeToggle()
	end
	
	-- Restart the float animation
	if not floatConnection then
		floatConnection = RunService.RenderStepped:Connect(function()
			local offsetY = math.sin(os.clock() * 1.8) * 8
			splashText.Position = UDim2.new(
				splashBasePos.X.Scale, splashBasePos.X.Offset,
				splashBasePos.Y.Scale, splashBasePos.Y.Offset + offsetY
			)
		end)
	end
	
	-- Fade in blur
	TweenService:Create(blurEffect, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = 24
	}):Play()
	
	for _, child in background:GetDescendants() do
		if child:IsA("TextLabel") then
			child.TextTransparency = 0
			if child.Name == "ComingSoonBadge" or child.Name == "VersionBadge" then
				child.BackgroundTransparency = 0
			end
		elseif child:IsA("TextButton") then
			child.TextTransparency = 0
			child.BackgroundTransparency = 0
		elseif child:IsA("ImageLabel") then
			child.ImageTransparency = 0
		elseif child:IsA("Frame") and not child:GetAttribute("KeepTransparent") then
			local targetTransparency = child:GetAttribute("TargetTransparency") or 0
			child.BackgroundTransparency = targetTransparency
		elseif child:IsA("UIStroke") then
			child.Transparency = 0
		end
	end
end

-- Function to start the game (activates camera, etc.)
local function startGame(mode: string)
	print("[TitleScreen] Starting game in " .. mode .. " mode!")
	gameWasPlayed = true
	
	-- Hide the title screen first
	hideTitleScreen()
	
	-- Tell the camera controller to activate
	if _G.CameraController and _G.CameraController.StartGame then
		_G.CameraController.StartGame()
	else
		-- Wait a bit and try again if camera controller isn't ready
		task.spawn(function()
			for i = 1, 20 do
				task.wait(0.1)
				if _G.CameraController and _G.CameraController.StartGame then
					_G.CameraController.StartGame()
					break
				end
			end
		end)
	end
	
	-- Fire event to server if needed
	local startGameEvent = ReplicatedStorage:FindFirstChild("StartGame")
	if startGameEvent then
		startGameEvent:FireServer(mode)
	end
	
	-- Signal MegaPlot that player is ready (release anchor/protection)
	local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if Remotes then
		local megaPlotReady = Remotes:FindFirstChild("MegaPlotPlayerReady")
		if megaPlotReady then
			megaPlotReady:FireServer()
		end
	end
end

-- Button click handlers
resumeButton.MouseButton1Click:Connect(function()
	print("[TitleScreen] Resume clicked - returning to game")
	startGame("Creative")
end)

creativeButton.MouseButton1Click:Connect(function()
	if isPrivateServer and isServerOwner and isFirstTimeSetup and not isIndividualMode then
		-- First-time setup in MegaPlot mode: open settings UI for configuration
		print("[TitleScreen] Opening first-time server setup...")
		settingsOpenedFromMenu = true
		local function openSettings()
			if _G.PrivateServerSettingsUI and _G.PrivateServerSettingsUI.Open then
				_G.PrivateServerSettingsUI.Open(true) -- true = setup mode
				return true
			end
			return false
		end
		
		if not openSettings() then
			task.spawn(function()
				for i = 1, 30 do
					task.wait(0.2)
					if openSettings() then break end
				end
			end)
		end
	elseif isPrivateServer and isServerOwner and not hasAnyWorlds and not isIndividualMode then
		-- No saved MegaPlot worlds: open settings to Create New World page
		print("[TitleScreen] No worlds yet, opening Create World...")
		settingsOpenedFromMenu = true
		local function openCreate()
			if _G.PrivateServerSettingsUI and _G.PrivateServerSettingsUI.OpenToCreate then
				_G.PrivateServerSettingsUI.OpenToCreate()
				return true
			end
			return false
		end
		
		if not openCreate() then
			task.spawn(function()
				for i = 1, 30 do
					task.wait(0.2)
					if openCreate() then break end
				end
			end)
		end
	elseif isPrivateServer and not isServerOwner and isFirstTimeSetup then
		-- Non-owner waiting for setup, do nothing
		print("[TitleScreen] Waiting for server owner to complete setup...")
	elseif isPrivateServer and isIndividualMode then
		-- Individual mode: just start the game directly
		print("[TitleScreen] Individual mode - starting game")
		
		-- Auto-complete first-time setup if needed (no wizard for Individual mode)
		if isFirstTimeSetup then
			isFirstTimeSetup = false
			local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
			if Remotes then
				local CompleteSetup = Remotes:FindFirstChild("CompletePrivateServerSetup")
				if CompleteSetup then
					CompleteSetup:FireServer()
				end
			end
		end
		
		startGame("Creative")
	elseif isPrivateServer and lastPlayedSlot then
		-- MegaPlot mode with a last-played world: auto-load it
		print("[TitleScreen] Auto-loading last played world: slot", lastPlayedSlot, lastPlayedSlotName)
		startGame("Creative")
		
		-- Show loading screen immediately
		if _G.MegaPlotLoadingScreen and _G.MegaPlotLoadingScreen.Show then
			_G.MegaPlotLoadingScreen.Show("Loading " .. (lastPlayedSlotName or "world") .. "...", true)
		end
		
		-- Fire load request to server
		local RemotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
		if RemotesFolder then
			local LoadMegaPlotFromSlot = RemotesFolder:FindFirstChild("LoadMegaPlotFromSlot")
			if not LoadMegaPlotFromSlot then
				LoadMegaPlotFromSlot = RemotesFolder:WaitForChild("LoadMegaPlotFromSlot", 10)
			end
			if LoadMegaPlotFromSlot then
				LoadMegaPlotFromSlot:FireServer(lastPlayedSlot)
			end
		end
	else
		-- Normal: enter the game
		startGame("Creative")
	end
end)

survivalButton.MouseButton1Click:Connect(function()
	if isPrivateServer and isServerOwner then
		-- Open the Worlds UI (not setup mode)
		print("[TitleScreen] Opening Worlds...")
		settingsOpenedFromMenu = true
		if _G.PrivateServerSettingsUI and _G.PrivateServerSettingsUI.Open then
			_G.PrivateServerSettingsUI.Open(false)
		else
			task.spawn(function()
				for i = 1, 20 do
					task.wait(0.2)
					if _G.PrivateServerSettingsUI and _G.PrivateServerSettingsUI.Open then
						_G.PrivateServerSettingsUI.Open(false)
						break
					end
				end
			end)
		end
	else
		print("[TitleScreen] Survival mode is coming soon!")
	end
end)

settingsButton.MouseButton1Click:Connect(function()
	if settingsIsModeCycle then
		-- Mode toggle behavior for server owner
		if modeToggleBusy then return end
		
		-- Cycle to the other mode
		local currentMode = isIndividualMode and "Individual" or "MegaPlot"
		local newMode = isIndividualMode and "MegaPlot" or "Individual"
		
		if pendingMode == nil then
			-- First click: show the other mode + confirm button
			pendingMode = newMode
			setButtonText(settingsButton, getModeButtonText(newMode))
			confirmModeButton.Visible = true
			modeWarningLabel.Visible = true
		elseif pendingMode == newMode then
			-- Clicked again while confirm is showing: cancel back to current
			resetModeToggle()
		else
			-- Pending was somehow the current mode, cycle forward
			pendingMode = newMode
			setButtonText(settingsButton, getModeButtonText(newMode))
			confirmModeButton.Visible = true
			modeWarningLabel.Visible = true
		end
	else
		-- Fallback: open Settings UI (shouldn't happen normally)
		print("[TitleScreen] Settings clicked!")
	end
end)

-- Confirm mode switch handler
confirmModeButton.MouseButton1Click:Connect(function()
	if not pendingMode or modeToggleBusy then return end
	modeToggleBusy = true
	
	setButtonText(confirmModeButton, "Switching...")
	
	task.spawn(function()
		-- Find the remote
		local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
		if not Remotes then Remotes = ReplicatedStorage:WaitForChild("Remotes", 10) end
		local SetPrivateServerMode = Remotes and Remotes:FindFirstChild("SetPrivateServerMode")
		if not SetPrivateServerMode then
			SetPrivateServerMode = Remotes and Remotes:WaitForChild("SetPrivateServerMode", 10)
		end
		
		if not SetPrivateServerMode then
			setButtonText(confirmModeButton, "Error!")
			task.wait(1.5)
			setButtonText(confirmModeButton, "Confirm Switch")
			modeToggleBusy = false
			return
		end
		
		-- Show loading screen during terrain regeneration
		local switchingToIndividual = (pendingMode ~= "MegaPlot")
		if _G.MegaPlotLoadingScreen and _G.MegaPlotLoadingScreen.Show then
			local msg = switchingToIndividual and "Switching to Individual Plots..." or "Switching to Mega Plot..."
			_G.MegaPlotLoadingScreen.Show(msg, true)
		end
		
		-- Fire ApplyPrivateServerSettings which handles mode change + terrain regeneration
		local ApplySettings = Remotes and Remotes:FindFirstChild("ApplyPrivateServerSettings")
		if not ApplySettings then
			ApplySettings = Remotes and Remotes:WaitForChild("ApplyPrivateServerSettings", 10)
		end
		
		if ApplySettings then
			ApplySettings:FireServer({
				mode = pendingMode,
				biome = "Plains",
				terrainStyle = "Flat",
				season = "Summer",
				weather = "Clear",
				confirmReset = "RESET",
			})
			
			-- Update client state
			isIndividualMode = switchingToIndividual
			setButtonText(confirmModeButton, "Done!")
			
			task.wait(1)
			
			-- Reset toggle UI
			setButtonText(confirmModeButton, "Confirm Switch")
			resetModeToggle()
			
			-- Update other buttons for new mode
			if isIndividualMode then
				setButtonText(creativeButton, gameWasPlayed and "Resume" or "Play")
				survivalButton.Visible = false
			else
				-- Re-check for saved worlds after mode switch
				hasAnyWorlds = checkForSavedWorlds()
				setButtonText(creativeButton, hasAnyWorlds and "Continue" or "Create World")
				-- Show Resume only if we have worlds and game was played
				if gameWasPlayed and hasAnyWorlds then
					resumeButton.Visible = true
					creativeButton.Visible = false
				else
					resumeButton.Visible = false
					creativeButton.Visible = true
				end
				survivalButton.Visible = true
				setButtonText(survivalButton, "Worlds")
				local wBadge4 = survivalButton:FindFirstChild("ComingSoonBadge")
				if wBadge4 then wBadge4.Visible = false end
			end
		else
			setButtonText(confirmModeButton, "Error!")
			task.wait(2)
			setButtonText(confirmModeButton, "Confirm Switch")
			resetModeToggle()
		end
		
		modeToggleBusy = false
	end)
end)

-- Mark transparent elements (containers that should stay transparent)
titleContainer:SetAttribute("KeepTransparent", true)
buttonContainer:SetAttribute("KeepTransparent", true)

-- Parent the GUI
screenGui.Parent = playerGui

-- Initial state - everything hidden for fade in
for _, child in background:GetDescendants() do
	if child:IsA("TextLabel") or child:IsA("TextButton") then
		child.TextTransparency = 1
		child.BackgroundTransparency = 1
	elseif child:IsA("ImageLabel") then
		child.ImageTransparency = 1
		child.BackgroundTransparency = 1
	elseif child:IsA("Frame") and not child:GetAttribute("KeepTransparent") then
		child.BackgroundTransparency = 1
	elseif child:IsA("UIStroke") then
		child.Transparency = 1
	end
end

-- Wait a moment for other UIs to initialize, then hide them
task.wait(0.5)
hideGameUIs()

-- Also keep checking for UIs that load later (including dynamically created ones)
task.spawn(function()
	for i = 1, 30 do
		task.wait(0.5)
		if screenGui.Enabled then
			hideGameUIs()
		else
			break -- Title screen closed, stop checking
		end
	end
end)

task.wait(0.1)

-- Fade in blur
TweenService:Create(blurEffect, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
	Size = 24
}):Play()

task.wait(0.2)

-- Fade in UI elements
for _, child in background:GetDescendants() do
	if child:IsA("TextLabel") then
		TweenService:Create(child, TweenInfo.new(0.6), {
			TextTransparency = 0
		}):Play()
		-- Fade in badge backgrounds (ComingSoonBadge and VersionBadge)
		if child.Name == "ComingSoonBadge" or child.Name == "VersionBadge" then
			TweenService:Create(child, TweenInfo.new(0.6), {
				BackgroundTransparency = 0
			}):Play()
		end
	elseif child:IsA("TextButton") then
		TweenService:Create(child, TweenInfo.new(0.6), {
			TextTransparency = 0,
			BackgroundTransparency = 0
		}):Play()
	elseif child:IsA("ImageLabel") then
		TweenService:Create(child, TweenInfo.new(0.6), {
			ImageTransparency = 0
		}):Play()
	elseif child:IsA("Frame") and not child:GetAttribute("KeepTransparent") then
		-- Restore frame backgrounds with target transparency
		local targetTransparency = child:GetAttribute("TargetTransparency") or 0
		TweenService:Create(child, TweenInfo.new(0.6), {
			BackgroundTransparency = targetTransparency
		}):Play()
	elseif child:IsA("UIStroke") then
		TweenService:Create(child, TweenInfo.new(0.6), {
			Transparency = 0
		}):Play()
	end
end

print("[TitleScreen] Title screen loaded!")

-- Export for other scripts
_G.TitleScreen = {
	Show = showTitleScreen,
	Hide = hideTitleScreen,
	IsOpen = function()
		return screenGui.Enabled
	end,
}

-- Shop button click: hide title screen WITHOUT starting game or showing game UIs
shopButton.MouseButton1Click:Connect(function()
	-- Don't use hideTitleScreen() because it sets gameWasPlayed=true
	-- and calls showGameUIs() which would show the hotbar
	
	-- Stop float animation
	if floatConnection then
		floatConnection:Disconnect()
		floatConnection = nil
	end
	
	-- Fade out blur
	TweenService:Create(blurEffect, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = 0
	}):Play()
	
	-- Fade all children
	for _, child in background:GetDescendants() do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			TweenService:Create(child, TweenInfo.new(0.3), {
				TextTransparency = 1, BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("ImageLabel") then
			TweenService:Create(child, TweenInfo.new(0.3), {
				ImageTransparency = 1, BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("Frame") then
			TweenService:Create(child, TweenInfo.new(0.3), {
				BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("UIStroke") then
			TweenService:Create(child, TweenInfo.new(0.3), { Transparency = 1 }):Play()
		end
	end
	
	task.wait(0.3)
	screenGui.Enabled = false
	-- NOTE: do NOT call showGameUIs() or set gameWasPlayed here
	
	if _G.ShopUI and _G.ShopUI.OpenFromTitleScreen then
		_G.ShopUI.OpenFromTitleScreen()
	end
end)

-- Plus button click: same pattern as Shop. Hides the title screen without
-- starting the game and hands off to PlusUI.OpenFromTitleScreen, which will
-- call back into _G.TitleScreen.Show() when the user closes the panel.
plusButton.MouseButton1Click:Connect(function()
	if floatConnection then
		floatConnection:Disconnect()
		floatConnection = nil
	end

	TweenService:Create(blurEffect, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = 0
	}):Play()

	for _, child in background:GetDescendants() do
		if child:IsA("TextLabel") or child:IsA("TextButton") then
			TweenService:Create(child, TweenInfo.new(0.3), {
				TextTransparency = 1, BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("ImageLabel") then
			TweenService:Create(child, TweenInfo.new(0.3), {
				ImageTransparency = 1, BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("Frame") then
			TweenService:Create(child, TweenInfo.new(0.3), {
				BackgroundTransparency = 1
			}):Play()
		elseif child:IsA("UIStroke") then
			TweenService:Create(child, TweenInfo.new(0.3), { Transparency = 1 }):Play()
		end
	end

	task.wait(0.3)
	screenGui.Enabled = false

	if _G.PlusUI and _G.PlusUI.OpenFromTitleScreen then
		_G.PlusUI.OpenFromTitleScreen()
	end
end)
