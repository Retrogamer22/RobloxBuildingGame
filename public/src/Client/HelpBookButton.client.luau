--[[
	HelpBookButton.client.luau
	HUD button that opens the Help Book (BuildBlox How to Play guide).
	Positioned on the right HUD strip, to the LEFT of the coin display.
	Right strip layout: [Book 36] [4] [Coins ~120] [4] [Menu 36] = 200px

	Self-contained ScreenGui (HelpBookButtonGui) so HelpBookUI can hide it
	independently when modals open (matches MainMenuButtonGui pattern).

	Renamed from RewardsBookButton.client.luau when the book slot was
	repurposed as the help guide instead of a collections book.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Dark style (matching MainMenuButton + CoinHUD)
local MC_BG = Color3.fromRGB(30, 30, 30)
local MC_BG_HOVER = Color3.fromRGB(45, 45, 45)
local MC_BG_PRESS = Color3.fromRGB(20, 20, 20)
local MC_BEVEL_LIGHT = Color3.fromRGB(80, 80, 80)
local MC_BEVEL_DARK = Color3.fromRGB(0, 0, 0)
local BEVEL = 2

-- Book accent colors (for the icon)
local BOOK_COVER = Color3.fromRGB(150, 90, 50)
local BOOK_COVER_DARK = Color3.fromRGB(100, 60, 30)
local BOOK_PAGES = Color3.fromRGB(235, 220, 180)
local BOOK_GOLD = Color3.fromRGB(220, 175, 60)

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

-- ============================================
-- LAYOUT (matches CoinHUD constants)
-- ============================================
local BTN_SIZE = IsMobile and 40 or 36
local GAP = 4
local RIGHT_MARGIN = IsMobile and 6 or 10
local BTN_Y = IsMobile and 34 or 4

-- Total HUD strip width (matches CoinHUD's TOTAL_W)
local TOTAL_W = IsMobile and 220 or 200
-- Book sits at the LEFT end of the strip
local BOOK_RIGHT = RIGHT_MARGIN + BTN_SIZE + GAP + (TOTAL_W - 2 * (BTN_SIZE + GAP)) + GAP

-- ============================================
-- CREATE UI
-- ============================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "HelpBookButtonGui"
screenGui.ResetOnSpawn = false
screenGui.ScreenInsets = Enum.ScreenInsets.None
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 10
screenGui.Enabled = false
screenGui.Parent = playerGui

local bookButton = Instance.new("TextButton")
bookButton.Name = "BookButton"
bookButton.Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE)
bookButton.Position = UDim2.new(1, -BOOK_RIGHT, 0, BTN_Y)
bookButton.AnchorPoint = Vector2.new(1, 0)
bookButton.BackgroundColor3 = MC_BG
bookButton.BackgroundTransparency = 0.2
bookButton.BorderSizePixel = 0
bookButton.Text = ""
bookButton.AutoButtonColor = false
bookButton.Parent = screenGui

local borders = addBevel(bookButton)
for _, bv in pairs(borders) do bv.BackgroundTransparency = 0.3 end

-- ============================================
-- BOOK ICON (small closed book with "?" emblem for "help")
-- ============================================
local ICON_W = IsMobile and 24 or 22
local ICON_H = IsMobile and 20 or 18

local iconHolder = Instance.new("Frame")
iconHolder.Name = "IconHolder"
iconHolder.Size = UDim2.new(0, ICON_W, 0, ICON_H)
iconHolder.Position = UDim2.new(0.5, 0, 0.5, 0)
iconHolder.AnchorPoint = Vector2.new(0.5, 0.5)
iconHolder.BackgroundColor3 = BOOK_COVER
iconHolder.BorderSizePixel = 0
iconHolder.ZIndex = bookButton.ZIndex + 2
iconHolder.Parent = bookButton

local iconBevel = Instance.new("Frame")
iconBevel.Size = UDim2.new(1, 0, 0, 1); iconBevel.Position = UDim2.new(0, 0, 0, 0)
iconBevel.BackgroundColor3 = Color3.fromRGB(190, 130, 80); iconBevel.BorderSizePixel = 0
iconBevel.ZIndex = iconHolder.ZIndex + 1; iconBevel.Parent = iconHolder

local iconBevel2 = Instance.new("Frame")
iconBevel2.Size = UDim2.new(1, 0, 0, 1); iconBevel2.Position = UDim2.new(0, 0, 1, -1)
iconBevel2.BackgroundColor3 = BOOK_COVER_DARK; iconBevel2.BorderSizePixel = 0
iconBevel2.ZIndex = iconHolder.ZIndex + 1; iconBevel2.Parent = iconHolder

-- Spine (left edge)
local spine = Instance.new("Frame")
spine.Name = "Spine"
spine.Size = UDim2.new(0, 3, 1, 0)
spine.Position = UDim2.new(0, 0, 0, 0)
spine.BackgroundColor3 = BOOK_COVER_DARK
spine.BorderSizePixel = 0
spine.ZIndex = iconHolder.ZIndex + 2
spine.Parent = iconHolder

-- Pages peek (right edge)
local pages = Instance.new("Frame")
pages.Name = "Pages"
pages.Size = UDim2.new(0, 2, 1, -4)
pages.Position = UDim2.new(1, -2, 0.5, 0)
pages.AnchorPoint = Vector2.new(0, 0.5)
pages.BackgroundColor3 = BOOK_PAGES
pages.BorderSizePixel = 0
pages.ZIndex = iconHolder.ZIndex + 2
pages.Parent = iconHolder

-- "?" emblem (replaces the diamond — this is a help book now)
local emblem = Instance.new("TextLabel")
emblem.Name = "Emblem"
emblem.Size = UDim2.new(0, 12, 0, 12)
emblem.Position = UDim2.new(0.5, 1, 0.5, 0)
emblem.AnchorPoint = Vector2.new(0.5, 0.5)
emblem.BackgroundTransparency = 1
emblem.Text = "?"
emblem.TextColor3 = BOOK_GOLD
emblem.Font = Enum.Font.Arcade
emblem.TextSize = IsMobile and 14 or 13
emblem.ZIndex = iconHolder.ZIndex + 3
emblem.Parent = iconHolder

-- Hotkey hint (desktop only, matches MainMenuButton style)
if not IsMobile then
	local hotkeyHint = Instance.new("TextLabel")
	hotkeyHint.Name = "HotkeyHint"
	hotkeyHint.Size = UDim2.new(0, 14, 0, 13)
	hotkeyHint.Position = UDim2.new(1, -1, 1, -1)
	hotkeyHint.AnchorPoint = Vector2.new(1, 1)
	hotkeyHint.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
	hotkeyHint.BackgroundTransparency = 0.2
	hotkeyHint.BorderSizePixel = 0
	hotkeyHint.Text = "B"
	hotkeyHint.TextColor3 = Color3.fromRGB(180, 180, 180)
	hotkeyHint.TextSize = 10
	hotkeyHint.Font = Enum.Font.Arcade
	hotkeyHint.ZIndex = bookButton.ZIndex + 5
	hotkeyHint.Parent = bookButton
end

-- ============================================
-- HOVER / PRESS
-- ============================================
bookButton.MouseEnter:Connect(function()
	bookButton.BackgroundColor3 = MC_BG_HOVER
end)
bookButton.MouseLeave:Connect(function()
	bookButton.BackgroundColor3 = MC_BG
	borders.top.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.left.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.bottom.BackgroundColor3 = MC_BEVEL_DARK
	borders.right.BackgroundColor3 = MC_BEVEL_DARK
end)
bookButton.MouseButton1Down:Connect(function()
	bookButton.BackgroundColor3 = MC_BG_PRESS
	borders.top.BackgroundColor3 = MC_BEVEL_DARK
	borders.left.BackgroundColor3 = MC_BEVEL_DARK
	borders.bottom.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.right.BackgroundColor3 = MC_BEVEL_LIGHT
end)
bookButton.MouseButton1Up:Connect(function()
	bookButton.BackgroundColor3 = MC_BG_HOVER
	borders.top.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.left.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.bottom.BackgroundColor3 = MC_BEVEL_DARK
	borders.right.BackgroundColor3 = MC_BEVEL_DARK
end)

bookButton.MouseButton1Click:Connect(function()
	if _G.HelpBookUI and _G.HelpBookUI.Toggle then
		_G.HelpBookUI.Toggle()
	end
end)

-- ============================================
-- VISIBILITY MANAGEMENT (matches MainMenuButton pattern)
-- Hides on title screen, shows once game starts
-- ============================================
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

print("[HelpBookButton] Loaded - Press B or click the book button to open")
