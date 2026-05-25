--[[
	PlusButton.client.luau

	HUD button that opens the Roblox Plus subscription panel (PlusUI).
	Positioned on the right HUD strip, immediately to the LEFT of the Help
	Book button.

	Layout (right→left along the top edge):
	  [Menu] [Coins] [HelpBook] [Plus]  ← all 36px / 40px squares, 4px gap

	Subtle pulse animation when the player is NOT subscribed, to gently
	advertise the perks without being intrusive. The pulse stops once they
	subscribe.

	Mirror MainMenuButton + HelpBookButton patterns (self-contained ScreenGui,
	visibility-toggle off the title screen, etc.) so other UIs can hide it
	independently when modals open.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- ============================================
-- COLORS
-- ============================================
-- Dark MC style for the button shell (matches HelpBook + Menu buttons).
local MC_BG = Color3.fromRGB(30, 30, 30)
local MC_BG_HOVER = Color3.fromRGB(45, 45, 45)
local MC_BG_PRESS = Color3.fromRGB(20, 20, 20)
local MC_BEVEL_LIGHT = Color3.fromRGB(80, 80, 80)
local MC_BEVEL_DARK = Color3.fromRGB(0, 0, 0)
local BEVEL = 2

-- Plus brand colors — sky-blue with gold accents. Echoes the cardboard-cloud
-- aesthetic of the game's room without copying Roblox's official Plus mark.
local PLUS_BG = Color3.fromRGB(76, 155, 230)
local PLUS_BG_DARK = Color3.fromRGB(48, 112, 188)
local PLUS_BG_LIGHT = Color3.fromRGB(140, 200, 255)
local PLUS_GOLD = Color3.fromRGB(244, 196, 48)
local PLUS_GOLD_DARK = Color3.fromRGB(170, 132, 28)

-- "Active subscriber" indicator color (green check)
local ACTIVE_GREEN = Color3.fromRGB(106, 190, 74)
local ACTIVE_GREEN_DARK = Color3.fromRGB(60, 130, 40)

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
-- LAYOUT (mirrors CoinHUD / HelpBookButton constants)
-- ============================================
local BTN_SIZE = IsMobile and 40 or 36
local GAP = 4
local RIGHT_MARGIN = IsMobile and 6 or 10
local BTN_Y = IsMobile and 34 or 4

-- Total HUD strip width (matches CoinHUD's TOTAL_W).
local TOTAL_W = IsMobile and 220 or 200
-- Help book sits at the LEFT end of the strip:
local BOOK_RIGHT = RIGHT_MARGIN + BTN_SIZE + GAP + (TOTAL_W - 2 * (BTN_SIZE + GAP)) + GAP
-- Plus sits one tile LEFT of the help book:
local PLUS_RIGHT = BOOK_RIGHT + BTN_SIZE + GAP

-- ============================================
-- CREATE UI
-- ============================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PlusButtonGui"
screenGui.ResetOnSpawn = false
screenGui.ScreenInsets = Enum.ScreenInsets.None
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.DisplayOrder = 10
screenGui.Enabled = false
screenGui.Parent = playerGui

local plusButton = Instance.new("TextButton")
plusButton.Name = "PlusButton"
plusButton.Size = UDim2.new(0, BTN_SIZE, 0, BTN_SIZE)
plusButton.Position = UDim2.new(1, -PLUS_RIGHT, 0, BTN_Y)
plusButton.AnchorPoint = Vector2.new(1, 0)
plusButton.BackgroundColor3 = MC_BG
plusButton.BackgroundTransparency = 0.2
plusButton.BorderSizePixel = 0
plusButton.Text = ""
plusButton.AutoButtonColor = false
plusButton.Parent = screenGui

local borders = addBevel(plusButton)
for _, bv in pairs(borders) do bv.BackgroundTransparency = 0.3 end

-- ============================================
-- PLUS ICON
-- A sky-blue beveled tile with the pixelated Roblox Plus logo on top. The
-- tile gives the brand a consistent "raised cardboard square" container that
-- matches the panel header, and stays the target for the gold-glow pulse.
-- ============================================
local ICON_SIZE = IsMobile and 24 or 22

local iconHolder = Instance.new("Frame")
iconHolder.Name = "IconHolder"
iconHolder.Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE)
iconHolder.Position = UDim2.new(0.5, 0, 0.5, 0)
iconHolder.AnchorPoint = Vector2.new(0.5, 0.5)
iconHolder.BackgroundColor3 = PLUS_BG
iconHolder.BorderSizePixel = 0
iconHolder.ZIndex = plusButton.ZIndex + 2
iconHolder.Parent = plusButton

-- Inner-tile bevel: light blue highlight on top/left, darker blue shadow on
-- bottom/right. Keeps the "raised cardboard square" feel of the brand.
local iconBevelTop = Instance.new("Frame")
iconBevelTop.Size = UDim2.new(1, 0, 0, 1); iconBevelTop.Position = UDim2.new(0, 0, 0, 0)
iconBevelTop.BackgroundColor3 = PLUS_BG_LIGHT; iconBevelTop.BorderSizePixel = 0
iconBevelTop.ZIndex = iconHolder.ZIndex + 1; iconBevelTop.Parent = iconHolder
local iconBevelLeft = Instance.new("Frame")
iconBevelLeft.Size = UDim2.new(0, 1, 1, 0); iconBevelLeft.Position = UDim2.new(0, 0, 0, 0)
iconBevelLeft.BackgroundColor3 = PLUS_BG_LIGHT; iconBevelLeft.BorderSizePixel = 0
iconBevelLeft.ZIndex = iconHolder.ZIndex + 1; iconBevelLeft.Parent = iconHolder
local iconBevelBottom = Instance.new("Frame")
iconBevelBottom.Size = UDim2.new(1, 0, 0, 1); iconBevelBottom.Position = UDim2.new(0, 0, 1, -1)
iconBevelBottom.BackgroundColor3 = PLUS_BG_DARK; iconBevelBottom.BorderSizePixel = 0
iconBevelBottom.ZIndex = iconHolder.ZIndex + 1; iconBevelBottom.Parent = iconHolder
local iconBevelRight = Instance.new("Frame")
iconBevelRight.Size = UDim2.new(0, 1, 1, 0); iconBevelRight.Position = UDim2.new(1, -1, 0, 0)
iconBevelRight.BackgroundColor3 = PLUS_BG_DARK; iconBevelRight.BorderSizePixel = 0
iconBevelRight.ZIndex = iconHolder.ZIndex + 1; iconBevelRight.Parent = iconHolder

-- The Plus logo — the official Roblox Plus glyph (utf8 0xE003), rendered as a
-- text character (same approach as the Robux glyph). White on the sky-blue
-- tile. The tile's bevel edges remain the target for the gold-glow pulse.
local plusIcon = Instance.new("TextLabel")
plusIcon.Name = "PlusIcon"
plusIcon.AnchorPoint = Vector2.new(0.5, 0.5)
plusIcon.Position = UDim2.new(0.5, 0, 0.5, 0)
plusIcon.Size = UDim2.new(1, 0, 1, 0)
plusIcon.BackgroundTransparency = 1
plusIcon.Text = utf8.char(0xE003)
plusIcon.TextColor3 = Color3.fromRGB(255, 255, 255)
plusIcon.Font = Enum.Font.GothamBold
plusIcon.TextSize = math.floor(ICON_SIZE * 0.7)
plusIcon.ZIndex = iconHolder.ZIndex + 2
plusIcon.Parent = iconHolder

-- ============================================
-- "ACTIVE" indicator — small green check tile in the bottom-right corner of
-- the button (NOT the icon) once the player is subscribed. Hidden otherwise.
-- ============================================
local activeDot = Instance.new("Frame")
activeDot.Name = "ActiveDot"
activeDot.Size = UDim2.new(0, 12, 0, 12)
activeDot.Position = UDim2.new(1, -2, 1, -2)
activeDot.AnchorPoint = Vector2.new(1, 1)
activeDot.BackgroundColor3 = ACTIVE_GREEN
activeDot.BorderSizePixel = 0
activeDot.Visible = false
activeDot.ZIndex = plusButton.ZIndex + 5
activeDot.Parent = plusButton
-- Tiny bevel on the dot so it doesn't look like a flat sticker.
local dotBevelTop = Instance.new("Frame")
dotBevelTop.Size = UDim2.new(1, 0, 0, 1); dotBevelTop.BackgroundColor3 = Color3.fromRGB(160, 230, 130)
dotBevelTop.BorderSizePixel = 0; dotBevelTop.ZIndex = activeDot.ZIndex + 1; dotBevelTop.Parent = activeDot
local dotBevelBottom = Instance.new("Frame")
dotBevelBottom.Size = UDim2.new(1, 0, 0, 1); dotBevelBottom.Position = UDim2.new(0, 0, 1, -1)
dotBevelBottom.BackgroundColor3 = ACTIVE_GREEN_DARK; dotBevelBottom.BorderSizePixel = 0
dotBevelBottom.ZIndex = activeDot.ZIndex + 1; dotBevelBottom.Parent = activeDot
-- Compact check mark — two diagonal frames inside.
local checkSmall = Instance.new("Frame")
checkSmall.Size = UDim2.new(0, 3, 0, 2); checkSmall.Position = UDim2.new(0, 2, 0, 6)
checkSmall.BackgroundColor3 = Color3.fromRGB(255, 255, 255); checkSmall.BorderSizePixel = 0
checkSmall.Rotation = 45; checkSmall.ZIndex = activeDot.ZIndex + 2; checkSmall.Parent = activeDot
local checkBig = Instance.new("Frame")
checkBig.Size = UDim2.new(0, 6, 0, 2); checkBig.Position = UDim2.new(0, 4, 0, 5)
checkBig.BackgroundColor3 = Color3.fromRGB(255, 255, 255); checkBig.BorderSizePixel = 0
checkBig.Rotation = -45; checkBig.ZIndex = activeDot.ZIndex + 2; checkBig.Parent = activeDot

-- ============================================
-- HOVER / PRESS
-- ============================================
plusButton.MouseEnter:Connect(function()
	plusButton.BackgroundColor3 = MC_BG_HOVER
end)
plusButton.MouseLeave:Connect(function()
	plusButton.BackgroundColor3 = MC_BG
	borders.top.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.left.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.bottom.BackgroundColor3 = MC_BEVEL_DARK
	borders.right.BackgroundColor3 = MC_BEVEL_DARK
end)
plusButton.MouseButton1Down:Connect(function()
	plusButton.BackgroundColor3 = MC_BG_PRESS
	borders.top.BackgroundColor3 = MC_BEVEL_DARK
	borders.left.BackgroundColor3 = MC_BEVEL_DARK
	borders.bottom.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.right.BackgroundColor3 = MC_BEVEL_LIGHT
end)
plusButton.MouseButton1Up:Connect(function()
	plusButton.BackgroundColor3 = MC_BG_HOVER
	borders.top.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.left.BackgroundColor3 = MC_BEVEL_LIGHT
	borders.bottom.BackgroundColor3 = MC_BEVEL_DARK
	borders.right.BackgroundColor3 = MC_BEVEL_DARK
end)

plusButton.MouseButton1Click:Connect(function()
	if _G.PlusUI and _G.PlusUI.Toggle then
		_G.PlusUI.Toggle()
	end
end)

-- ============================================
-- PULSE ANIMATION (when NOT subscribed)
-- Small, slow gold-glow pulse on the icon edge — easy to ignore, easy to
-- notice if you're looking around the HUD.
-- ============================================
local pulseTween = nil
local function startPulse()
	if pulseTween then return end
	-- Tween the icon-bevel-light color to brighter and back. Loop forever.
	local info = TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	pulseTween = TweenService:Create(iconBevelTop, info, {
		BackgroundColor3 = Color3.fromRGB(220, 240, 255),
	})
	pulseTween:Play()
	-- Mirror the same tween on the left bevel for a coherent glow.
	TweenService:Create(iconBevelLeft, info, {
		BackgroundColor3 = Color3.fromRGB(220, 240, 255),
	}):Play()
end
local function stopPulse()
	if pulseTween then
		pulseTween:Cancel()
		pulseTween = nil
	end
	iconBevelTop.BackgroundColor3 = PLUS_BG_LIGHT
	iconBevelLeft.BackgroundColor3 = PLUS_BG_LIGHT
end

-- ============================================
-- SUBSCRIPTION STATE → APPEARANCE
-- ============================================
local function applyPlusState()
	local controller = _G.PlusController
	local subbed = controller and controller.IsSubscribed and controller.IsSubscribed() or false
	if subbed then
		activeDot.Visible = true
		stopPulse()
	else
		activeDot.Visible = false
		startPulse()
	end
end

-- Initial application + listen for changes.
task.spawn(function()
	-- PlusController might still be initializing — poll briefly.
	for _ = 1, 30 do
		if _G.PlusController then break end
		task.wait(0.2)
	end
	applyPlusState()
	if _G.PlusController and _G.PlusController.OnChanged then
		_G.PlusController.OnChanged(applyPlusState)
	end
end)

-- ============================================
-- VISIBILITY MANAGEMENT (mirrors HelpBookButton)
-- Hides on title screen, shows once game starts.
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

print("[BB-PLUS] PlusButton loaded — click for Roblox Plus perks")
