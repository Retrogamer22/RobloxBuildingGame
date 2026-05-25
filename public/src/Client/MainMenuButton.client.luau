--[[
	MainMenuButton.client.luau
	Provides a button and hotkey (M) to return to the main menu
	Positioned to the left of the player list with MC styling
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Dark style (matching player list)
local MC_BG = Color3.fromRGB(30, 30, 30)
local MC_BG_HOVER = Color3.fromRGB(45, 45, 45)
local MC_BG_PRESS = Color3.fromRGB(20, 20, 20)
local MC_BEVEL_LIGHT = Color3.fromRGB(80, 80, 80)
local MC_BEVEL_DARK = Color3.fromRGB(0, 0, 0)
local BEVEL = 2

local function addBevel(parent, hlColor, shColor)
	local hl = hlColor or MC_BEVEL_LIGHT
	local sh = shColor or MC_BEVEL_DARK
	local top = Instance.new("Frame")
	top.Name = "BorderTop"; top.Size = UDim2.new(1, 0, 0, BEVEL)
	top.BackgroundColor3 = hl; top.BorderSizePixel = 0; top.ZIndex = parent.ZIndex + 1; top.Parent = parent
	local left = Instance.new("Frame")
	left.Name = "BorderLeft"; left.Size = UDim2.new(0, BEVEL, 1, 0)
	left.BackgroundColor3 = hl; left.BorderSizePixel = 0; left.ZIndex = parent.ZIndex + 1; left.Parent = parent
	local bottom = Instance.new("Frame")
	bottom.Name = "BorderBottom"; bottom.Size = UDim2.new(1, 0, 0, BEVEL); bottom.Position = UDim2.new(0, 0, 1, -BEVEL)
	bottom.BackgroundColor3 = sh; bottom.BorderSizePixel = 0; bottom.ZIndex = parent.ZIndex + 1; bottom.Parent = parent
	local right = Instance.new("Frame")
	right.Name = "BorderRight"; right.Size = UDim2.new(0, BEVEL, 1, 0); right.Position = UDim2.new(1, -BEVEL, 0, 0)
	right.BackgroundColor3 = sh; right.BorderSizePixel = 0; right.ZIndex = parent.ZIndex + 1; right.Parent = parent
	return {top = top, left = left, bottom = bottom, right = right}
end

-- ===== CREATE UI =====
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MainMenuButtonGui"
screenGui.ResetOnSpawn = false
screenGui.ScreenInsets = Enum.ScreenInsets.None
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 10
screenGui.Enabled = false

local btnSize = IsMobile and 40 or 36

-- Position: right-aligned with the Roblox player list, sitting just above it
-- ScreenInsets = None so we're working with full screen coords
-- Roblox player list sits flush to the right edge with minimal margin
-- Positioned to right-align with the player list (right edge at margin)
local RIGHT_MARGIN = IsMobile and 6 or 10
local btnY = IsMobile and 34 or 4

local menuButton = Instance.new("TextButton")
menuButton.Name = "MenuButton"
menuButton.Size = UDim2.new(0, btnSize, 0, btnSize)
menuButton.Position = UDim2.new(1, -RIGHT_MARGIN, 0, btnY)
menuButton.AnchorPoint = Vector2.new(1, 0)
menuButton.BackgroundColor3 = MC_BG
menuButton.BackgroundTransparency = 0.2
menuButton.BorderSizePixel = 0
menuButton.Text = ""
menuButton.AutoButtonColor = false
menuButton.Parent = screenGui

local borders = addBevel(menuButton)
for _, bv in pairs(borders) do bv.BackgroundTransparency = 0.3 end

-- Hamburger icon: 3 horizontal lines using Frames
local LINE_WIDTH = IsMobile and 18 or 16
local LINE_HEIGHT = 2
local LINE_GAP = IsMobile and 5 or 4
local totalLinesHeight = LINE_HEIGHT * 3 + LINE_GAP * 2

for i = 0, 2 do
	local line = Instance.new("Frame")
	line.Name = "HamburgerLine" .. (i + 1)
	line.Size = UDim2.new(0, LINE_WIDTH, 0, LINE_HEIGHT)
	line.Position = UDim2.new(0.5, -LINE_WIDTH / 2, 0.5, -totalLinesHeight / 2 + i * (LINE_HEIGHT + LINE_GAP))
	line.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	line.BorderSizePixel = 0
	line.ZIndex = menuButton.ZIndex + 2
	line.Parent = menuButton
end

-- Hotkey hint (desktop only)
if not IsMobile then
	local hotkeyHint = Instance.new("TextLabel")
	hotkeyHint.Name = "HotkeyHint"
	hotkeyHint.Size = UDim2.new(0, 18, 0, 13)
	hotkeyHint.Position = UDim2.new(1, -1, 1, -1)
	hotkeyHint.AnchorPoint = Vector2.new(1, 1)
	hotkeyHint.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
	hotkeyHint.BackgroundTransparency = 0.2
	hotkeyHint.BorderSizePixel = 0
	hotkeyHint.Text = "M"
	hotkeyHint.TextColor3 = Color3.fromRGB(180, 180, 180)
	hotkeyHint.TextSize = 10
	hotkeyHint.Font = Enum.Font.Arcade
	hotkeyHint.ZIndex = menuButton.ZIndex + 3
	hotkeyHint.Parent = menuButton
end

-- Hover effects
menuButton.MouseEnter:Connect(function()
	menuButton.BackgroundColor3 = MC_BG_HOVER
end)
menuButton.MouseLeave:Connect(function()
	menuButton.BackgroundColor3 = MC_BG
end)
menuButton.MouseButton1Down:Connect(function()
	menuButton.BackgroundColor3 = MC_BG_PRESS
	borders.top.BackgroundColor3 = MC_BEVEL_DARK
	borders.left.BackgroundColor3 = MC_BEVEL_DARK
	borders.bottom.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.right.BackgroundColor3 = MC_BEVEL_LIGHT
end)
menuButton.MouseButton1Up:Connect(function()
	menuButton.BackgroundColor3 = MC_BG_HOVER
	borders.top.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.left.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.bottom.BackgroundColor3 = MC_BEVEL_DARK
	borders.right.BackgroundColor3 = MC_BEVEL_DARK
end)

-- ===== RETURN TO MENU LOGIC =====
local function returnToMenu()
	if _G.TitleScreen and _G.TitleScreen.IsOpen and _G.TitleScreen.IsOpen() then return end
	if _G.CameraController and _G.CameraController.IsGameStarted and not _G.CameraController.IsGameStarted() then return end

	print("[MainMenuButton] Returning to main menu")

	if _G.CameraController and _G.CameraController.ReturnToMenu then
		_G.CameraController.ReturnToMenu()
	end
	if _G.TitleScreen and _G.TitleScreen.Show then
		_G.TitleScreen.Show()
	end

	screenGui.Enabled = false
end

menuButton.MouseButton1Click:Connect(returnToMenu)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.M then
		local focusedTextBox = UserInputService:GetFocusedTextBox()
		if focusedTextBox then return end
		returnToMenu()
	end
end)

-- ===== VISIBILITY MANAGEMENT =====
task.spawn(function()
	while not _G.TitleScreen do
		task.wait(0.1)
	end
	while true do
		task.wait(0.3)
		if _G.TitleScreen and _G.TitleScreen.IsOpen then
			local titleOpen = _G.TitleScreen.IsOpen()
			if not titleOpen and not screenGui.Enabled then
				screenGui.Enabled = true
			elseif titleOpen and screenGui.Enabled then
				screenGui.Enabled = false
			end
		end
	end
end)

screenGui.Parent = playerGui

print("[MainMenuButton] Loaded - Press M or click the menu button to return to main menu")
