--[[
	HelpBookUI.client.luau
	In-game beginner guide ("How to Play"). Sidebar tab layout modeled on
	InventoryController: vertical tabs on the left edge (tucked partially
	under the panel), main content in the centered panel.

	Opens via:
	  - Book button on right HUD strip (HelpBookButtonGui)
	  - Hotkey: B
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local LOG_PREFIX = "[BB-HELP]"

-- Folders we'll pull preview blocks from (matches InventoryController setup).
local BlocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)
local BlockTemplates = ReplicatedStorage:WaitForChild("BlockTemplates", 10)

local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local FONT = Enum.Font.Arcade
local FONT_BODY = Enum.Font.Gotham
local BEVEL = 2

local C = {
	-- Modal (matches inventory's dark slate)
	panelBg = Color3.fromRGB(28, 28, 32),
	surface = Color3.fromRGB(40, 40, 40),       -- Tab surface (matches Colors.Surface)
	surfaceHover = Color3.fromRGB(55, 55, 55),
	surfaceActive = Color3.fromRGB(70, 70, 80),
	headerBg = Color3.fromRGB(45, 42, 42),
	bevelHL = Color3.fromRGB(70, 70, 70),
	bevelSH = Color3.fromRGB(14, 14, 14),

	-- Cards
	cardBg = Color3.fromRGB(38, 38, 42),
	cardBevelHL = Color3.fromRGB(60, 60, 66),
	cardBevelSH = Color3.fromRGB(16, 16, 18),

	-- Badge
	badgeBg = Color3.fromRGB(12, 10, 10),
	badgeText = Color3.fromRGB(244, 196, 48),

	-- Buttons
	closeBtn = Color3.fromRGB(180, 50, 50),
	closeBtnHover = Color3.fromRGB(210, 70, 70),
	closeBtnPress = Color3.fromRGB(140, 35, 35),
	closeBtnHL = Color3.fromRGB(220, 100, 100),
	closeBtnSH = Color3.fromRGB(100, 30, 30),

	-- Text
	textWhite = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(190, 180, 170),
	textMuted = Color3.fromRGB(130, 122, 112),

	-- Accents
	gold = Color3.fromRGB(244, 196, 48),
	goldDark = Color3.fromRGB(170, 132, 28),
	coral = Color3.fromRGB(255, 123, 71),
	grass = Color3.fromRGB(106, 190, 74),
	berry = Color3.fromRGB(200, 75, 107),
	sky = Color3.fromRGB(74, 155, 209),
	wood = Color3.fromRGB(176, 121, 67),

	-- Tip
	tipBg = Color3.fromRGB(54, 44, 22),
	tipHL = Color3.fromRGB(120, 90, 30),
	tipSH = Color3.fromRGB(30, 22, 8),

	overlay = Color3.fromRGB(0, 0, 0),
}

local IsOpen = false
local currentPage = 1
local pages = {}
local tabButtons = {}
local tabBevels = {}
local tabAccents = {}

_G.HelpBookUI = {
	IsOpen = function() return IsOpen end,
}

-- ============================================
-- HELPERS
-- ============================================
local function addBevel(frame, hlColor, shColor, bevelSize)
	local hl = hlColor or C.bevelHL
	local sh = shColor or C.bevelSH
	local b = bevelSize or BEVEL
	local z = frame.ZIndex + 1
	local top = Instance.new("Frame"); top.Name = "BT"; top.Size = UDim2.new(1, 0, 0, b)
	top.BackgroundColor3 = hl; top.BorderSizePixel = 0; top.ZIndex = z; top.Parent = frame
	local left = Instance.new("Frame"); left.Name = "BL"; left.Size = UDim2.new(0, b, 1, 0)
	left.BackgroundColor3 = hl; left.BorderSizePixel = 0; left.ZIndex = z; left.Parent = frame
	local bottom = Instance.new("Frame"); bottom.Name = "BB"; bottom.Size = UDim2.new(1, 0, 0, b)
	bottom.Position = UDim2.new(0, 0, 1, -b)
	bottom.BackgroundColor3 = sh; bottom.BorderSizePixel = 0; bottom.ZIndex = z; bottom.Parent = frame
	local right = Instance.new("Frame"); right.Name = "BR"; right.Size = UDim2.new(0, b, 1, 0)
	right.Position = UDim2.new(1, -b, 0, 0)
	right.BackgroundColor3 = sh; right.BorderSizePixel = 0; right.ZIndex = z; right.Parent = frame
	return {top = top, left = left, bottom = bottom, right = right}
end

local function setBevel(bv, hl, sh)
	bv.top.BackgroundColor3 = hl; bv.left.BackgroundColor3 = hl
	bv.bottom.BackgroundColor3 = sh; bv.right.BackgroundColor3 = sh
end

-- ============================================
-- VIEWPORT BLOCK PREVIEW (matches InventoryController pattern)
-- iconBlock = template name, iconFolderName = folder in ReplicatedStorage,
-- color/material = optional appearance overrides (e.g. wood color for
-- CraftingTable which ships uncolored), isTool = use tool camera framing.
-- ============================================
local function createBlockViewport(parent, size, iconBlock, iconFolderName, color, material, isTool, leatherTint)
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "BlockPreview"
	viewport.Size = size
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(160, 160, 160)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-1, -1.5, -0.5).Unit
	viewport.Parent = parent

	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "World"
	worldModel.Parent = viewport

	local camera = Instance.new("Camera")
	camera.FieldOfView = 39
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local folder = ReplicatedStorage:FindFirstChild(iconFolderName)
	if not folder then return viewport end
	local template = folder:FindFirstChild(iconBlock)
	if not template then return viewport end

	local model = template:Clone()
	local isCraftingTable = iconBlock == "CraftingTable"

	-- Crafting table needs special handling: it has Block / Edge / Side / Top
	-- parts, and Side+Top carry Decals/Textures for the tool-layout art.
	-- Coloring those parts overwrites their template look, and the decals on
	-- top need their own tint to read as wood-on-wood instead of bright white.
	local ctEdgeTrimColor
	if isCraftingTable and color then
		local h, s, v = Color3.toHSV(color)
		ctEdgeTrimColor = Color3.fromHSV(h, s * 0.75, v * 0.38)
	end
	if isCraftingTable and leatherTint then
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA("Texture") or desc:IsA("Decal") then
				local parentName = desc.Parent and desc.Parent.Name or ""
				if parentName == "Side" or parentName == "Top" then
					desc.Color3 = leatherTint
				end
			end
		end
	end

	-- Apply color/material to all parts if specified
	local function applyAppearance(part)
		if not part:IsA("BasePart") then return end
		part.Anchored = true
		if isCraftingTable then
			-- Block = wood; Edge = darkened trim; Side/Top keep template look.
			if part.Name == "Block" then
				if color then part.Color = color end
				if material then part.Material = material end
			elseif part.Name == "Edge" then
				if ctEdgeTrimColor then part.Color = ctEdgeTrimColor end
			end
		else
			if color then part.Color = color end
			if material then part.Material = material end
		end
	end

	if model:IsA("BasePart") then
		applyAppearance(model)
		if isTool then
			model.CFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(180), 0)
		else
			model.CFrame = CFrame.new(0, 0, 0)
		end
	elseif model:IsA("Model") then
		for _, desc in ipairs(model:GetDescendants()) do applyAppearance(desc) end
		if isTool then
			model:PivotTo(CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(180), 0))
		elseif isCraftingTable then
			-- Crafting table has a center pivot; -0.3 keeps it near viewport
			-- center instead of dropping it well below frame like a bottom-pivot model.
			model:PivotTo(CFrame.new(0, -0.3, 0))
		else
			local isLog = iconBlock and string.find(iconBlock, "Log")
			if not isLog then
				model:PivotTo(CFrame.new(0, -1.5, 0))
			else
				model:PivotTo(CFrame.new(0, 0, 0))
			end
		end
	end
	model.Parent = worldModel

	if isTool then
		-- Tools render flat-faced toward camera
		camera.CFrame = CFrame.new(Vector3.new(0, 0, 5), Vector3.new(0, 0, 0))
	else
		-- Isometric block view
		camera.CFrame = CFrame.new(Vector3.new(5.5, 4.4, 5.5), Vector3.new(0, 0, 0))
	end
	return viewport
end

-- Step card. Fixed height — no AutomaticSize stacking which causes
-- compounding offset bugs when nested inside other AutomaticSize layouts.
-- Title and controls are accent-colored; body stays neutral for readability.
-- Title and body are top-aligned; controls are bottom-aligned so cards in
-- a row align both at the top and bottom.
local function createCard(num, title, body, controlsText, parent, accent, overrideHeight)
	local card = Instance.new("Frame")
	card.Name = "Card_" .. title
	local hasControls = controlsText ~= nil
	local bodyLines = math.ceil(#body / 40)  -- ~40 chars/line at half-width
	local bodyH = math.max(20, bodyLines * 16)
	local titleH = 24
	local controlsH = hasControls and 20 or 0
	local gap1 = 4
	local gap2 = 4
	local contentH = titleH + gap1 + bodyH + (hasControls and (gap2 + controlsH) or 0)
	local padding = 14
	local h = overrideHeight or (contentH + padding * 2)
	card.Size = UDim2.new(0.5, -5, 0, h)
	card.BorderSizePixel = 0
	card.ZIndex = 5
	card.Parent = parent
	-- Card tinted with the accent color (darkened so text stays readable),
	-- and bevels derived from the same color so the whole card reads as one
	-- themed surface — no separate accent stripe needed.
	local accentColor = accent or C.gold
	local tintedBg = Color3.new(
		math.clamp(accentColor.R * 0.15 + 0.08, 0, 1),
		math.clamp(accentColor.G * 0.15 + 0.08, 0, 1),
		math.clamp(accentColor.B * 0.15 + 0.08, 0, 1)
	)
	local tintedHL = Color3.new(
		math.clamp(accentColor.R * 0.35 + 0.15, 0, 1),
		math.clamp(accentColor.G * 0.35 + 0.15, 0, 1),
		math.clamp(accentColor.B * 0.35 + 0.15, 0, 1)
	)
	local tintedSH = Color3.new(
		math.clamp(accentColor.R * 0.05 + 0.04, 0, 1),
		math.clamp(accentColor.G * 0.05 + 0.04, 0, 1),
		math.clamp(accentColor.B * 0.05 + 0.04, 0, 1)
	)
	card.BackgroundColor3 = tintedBg
	addBevel(card, tintedHL, tintedSH, 3)

	-- Top-align title and body, bottom-align controls text. This keeps cards
	-- in a row visually aligned across BOTH the top (titles) and bottom
	-- (controls) even when one card has more body text than its rowmate —
	-- the extra height just becomes breathing room between body and controls.
	local topY = padding

	local titleLbl = Instance.new("TextLabel")
	titleLbl.BackgroundTransparency = 1
	titleLbl.Position = UDim2.fromOffset(padding, topY)
	titleLbl.Size = UDim2.new(1, -padding * 2, 0, titleH)
	titleLbl.Font = FONT
	titleLbl.Text = title
	titleLbl.TextColor3 = accentColor
	titleLbl.TextSize = 20
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.TextYAlignment = Enum.TextYAlignment.Center
	titleLbl.TextTruncate = Enum.TextTruncate.AtEnd
	titleLbl.ZIndex = card.ZIndex + 1
	titleLbl.Parent = card

	local bodyLbl = Instance.new("TextLabel")
	bodyLbl.BackgroundTransparency = 1
	bodyLbl.Position = UDim2.fromOffset(padding, topY + titleH + gap1)
	bodyLbl.Size = UDim2.new(1, -padding * 2, 0, bodyH)
	bodyLbl.Font = FONT_BODY
	bodyLbl.Text = body
	bodyLbl.TextColor3 = C.textDim
	bodyLbl.TextSize = 13
	bodyLbl.TextWrapped = true
	bodyLbl.TextXAlignment = Enum.TextXAlignment.Left
	bodyLbl.TextYAlignment = Enum.TextYAlignment.Top
	bodyLbl.TextTruncate = Enum.TextTruncate.AtEnd
	bodyLbl.ZIndex = card.ZIndex + 1
	bodyLbl.Parent = card

	if controlsText then
		-- Controls text sits directly on the card (no inset chip). Accent-colored
		-- + Arcade font + slightly larger size makes it read as a callout.
		local ctrl = Instance.new("TextLabel")
		ctrl.BackgroundTransparency = 1
		ctrl.Position = UDim2.fromOffset(padding, h - padding - controlsH)
		ctrl.Size = UDim2.new(1, -padding * 2, 0, controlsH)
		ctrl.Font = FONT
		local pcPart, mobilePart = controlsText:match("^(.-)%s*|%s*(.+)$")
		local displayText = controlsText
		if pcPart and mobilePart then
			displayText = IsMobile and mobilePart or pcPart
			displayText = displayText:gsub("^%s*PC:%s*", ""):gsub("^%s*Mobile:%s*", "")
		end
		ctrl.Text = displayText
		ctrl.TextColor3 = accentColor
		ctrl.TextSize = 14
		ctrl.TextXAlignment = Enum.TextXAlignment.Left
		ctrl.TextYAlignment = Enum.TextYAlignment.Center
		ctrl.TextTruncate = Enum.TextTruncate.AtEnd
		ctrl.ZIndex = card.ZIndex + 1
		ctrl.Parent = card
	end

	return card
end

-- Section header with viewport block icon + trailing horizontal line in accent color
-- iconOpts = { color = Color3, material = Enum.Material, isTool = bool } (optional)
local function createSectionLabel(text, accent, iconBlock, iconFolder, parent, iconOpts)
	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 48)
	row.Parent = parent

	-- Block viewport icon
	local iconHolder = Instance.new("Frame")
	iconHolder.BackgroundColor3 = C.cardBg
	iconHolder.Position = UDim2.fromOffset(0, 2)
	iconHolder.Size = UDim2.fromOffset(44, 44)
	iconHolder.BorderSizePixel = 0
	iconHolder.Parent = row
	addBevel(iconHolder, C.cardBevelHL, C.cardBevelSH, 2)
	if iconBlock and iconFolder then
		local opts = iconOpts or {}
		local vp = createBlockViewport(iconHolder, UDim2.new(1, -4, 1, -4),
			iconBlock, iconFolder, opts.color, opts.material, opts.isTool, opts.leatherTint)
		vp.Position = UDim2.fromOffset(2, 2)
	else
		local solid = Instance.new("Frame")
		solid.BackgroundColor3 = accent
		solid.Position = UDim2.fromOffset(6, 6)
		solid.Size = UDim2.fromOffset(16, 16)
		solid.BorderSizePixel = 0
		solid.Parent = iconHolder
	end

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(56, 0)
	label.Size = UDim2.new(1, -56, 1, 0)
	label.Font = FONT
	label.Text = text
	label.TextColor3 = accent
	label.TextSize = 18
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = row

	return row
end

-- Tip box (fixed height, no AutomaticSize stacking)
local function createTip(strong, body, parent)
	local bodyLines = math.ceil(#body / 60)
	local h = 10 + 20 + math.max(20, bodyLines * 16) + 10

	local tip = Instance.new("Frame")
	tip.BackgroundColor3 = C.tipBg
	tip.Size = UDim2.new(1, 0, 0, h)
	tip.BorderSizePixel = 0
	tip.ZIndex = 5
	tip.Parent = parent
	addBevel(tip, C.tipHL, C.tipSH, 2)

	local bang = Instance.new("Frame")
	bang.BackgroundColor3 = C.gold
	bang.Position = UDim2.fromOffset(10, 10)
	bang.Size = UDim2.fromOffset(22, 22)
	bang.BorderSizePixel = 0
	bang.ZIndex = tip.ZIndex + 1
	bang.Parent = tip
	local bangText = Instance.new("TextLabel")
	bangText.BackgroundTransparency = 1
	bangText.Size = UDim2.fromScale(1, 1)
	bangText.Font = FONT
	bangText.Text = "!"
	bangText.TextColor3 = Color3.fromRGB(20, 18, 10)
	bangText.TextSize = 16
	bangText.ZIndex = bang.ZIndex + 1
	bangText.Parent = bang

	local strongLbl = Instance.new("TextLabel")
	strongLbl.BackgroundTransparency = 1
	strongLbl.Position = UDim2.fromOffset(44, 10)
	strongLbl.Size = UDim2.new(1, -58, 0, 18)
	strongLbl.Font = FONT
	strongLbl.Text = strong
	strongLbl.TextColor3 = C.gold
	strongLbl.TextSize = 14
	strongLbl.TextXAlignment = Enum.TextXAlignment.Left
	strongLbl.ZIndex = tip.ZIndex + 1
	strongLbl.Parent = tip

	local bodyLbl = Instance.new("TextLabel")
	bodyLbl.BackgroundTransparency = 1
	bodyLbl.Position = UDim2.fromOffset(44, 30)
	bodyLbl.Size = UDim2.new(1, -58, 0, math.max(20, bodyLines * 16))
	bodyLbl.Font = FONT_BODY
	bodyLbl.Text = body
	bodyLbl.TextColor3 = C.textDim
	bodyLbl.TextSize = 12
	bodyLbl.TextWrapped = true
	bodyLbl.TextXAlignment = Enum.TextXAlignment.Left
	bodyLbl.TextYAlignment = Enum.TextYAlignment.Top
	bodyLbl.ZIndex = tip.ZIndex + 1
	bodyLbl.Parent = tip

	return tip
end

-- ============================================
-- ROOT GUI
-- ============================================
-- Clean up any leftover instances from previous script runs (Studio hot-reloads,
-- or earlier versions of this script in the same session). ResetOnSpawn=false
-- means old ScreenGuis survive respawns, so we have to do it manually.
for _, existing in ipairs(PlayerGui:GetChildren()) do
	if existing.Name == "HelpBookUI" then
		existing:Destroy()
	end
end
for _, existing in ipairs(Lighting:GetChildren()) do
	if existing.Name == "HelpBookBlur" then
		existing:Destroy()
	end
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "HelpBookUI"; ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 25; ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Enabled = false; ScreenGui.Parent = PlayerGui

local Overlay = Instance.new("Frame")
Overlay.Name = "Overlay"
Overlay.Size = UDim2.new(1, 0, 1, 0)
Overlay.BackgroundColor3 = C.overlay
Overlay.BackgroundTransparency = 1
Overlay.BorderSizePixel = 0
Overlay.ZIndex = 1
Overlay.Active = false  -- Don't intercept clicks; we add a separate dedicated click-catcher
Overlay.Parent = ScreenGui

-- Dedicated click-catcher for closing the modal by clicking outside.
-- Sits between Overlay and Wrapper. Lower ZIndex than Wrapper so clicks on
-- the panel/tabs land on the Wrapper instead of bubbling here.
local ClickCatcher = Instance.new("TextButton")
ClickCatcher.Name = "ClickCatcher"
ClickCatcher.Size = UDim2.new(1, 0, 1, 0)
ClickCatcher.BackgroundTransparency = 1
ClickCatcher.BorderSizePixel = 0
ClickCatcher.Text = ""
ClickCatcher.AutoButtonColor = false
ClickCatcher.ZIndex = 1
ClickCatcher.Parent = ScreenGui

-- Outer wrapper: full size, transparent. Tabs and PanelBg are siblings of
-- this. Mirrors InventoryController's InventoryPanel approach exactly.
-- Active=true is critical — it makes the wrapper consume clicks so they don't
-- bubble through to the ClickCatcher behind it.
local panelW = IsMobile and 0.98 or 740
local panelH = IsMobile and 0.85 or 460
local panelSize = IsMobile and UDim2.new(panelW, 0, panelH, 0) or UDim2.new(0, panelW, 0, panelH)

local Wrapper = Instance.new("Frame")
Wrapper.Name = "Wrapper"
Wrapper.AnchorPoint = Vector2.new(0.5, 0.5)
Wrapper.Position = UDim2.new(0.5, 0, 0.5, 0)
Wrapper.Size = panelSize
Wrapper.BackgroundTransparency = 1
Wrapper.BorderSizePixel = 0
Wrapper.ClipsDescendants = false
Wrapper.ZIndex = 2
Wrapper.Parent = ScreenGui

-- Visible inner PanelBg (inset 58px from each side on desktop; on mobile,
-- inset only on the left to leave room for the vertical tab strip.)
local PanelBg = Instance.new("Frame")
PanelBg.Name = "PanelBg"
if IsMobile then
	PanelBg.Position = UDim2.new(0, 72, 0, 0)
	PanelBg.Size = UDim2.new(1, -72, 1, 0)
else
	PanelBg.Position = UDim2.new(0, 58, 0, 0)
	PanelBg.Size = UDim2.new(1, -116, 1, 0)
end
PanelBg.BackgroundColor3 = C.panelBg
PanelBg.BorderSizePixel = 0
PanelBg.ZIndex = 1
PanelBg.Parent = Wrapper
local panelBevels = addBevel(PanelBg)

-- Hide the bevels touching tabs so they connect flush.
if IsMobile then
	panelBevels.left.Visible = false
else
	panelBevels.left.Visible = false
	panelBevels.right.Visible = false
end

-- Use PanelBg as the "Panel" the rest of the code references
local Panel = PanelBg

-- ============================================
-- HEADER (inside the panel)
-- ============================================
local HEADER_H = 44

local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, HEADER_H)
Header.BackgroundColor3 = C.headerBg
Header.BorderSizePixel = 0
Header.ZIndex = 3
Header.Parent = Panel
addBevel(Header, C.bevelHL, C.bevelSH, 3)

-- Logo blocks
local logoColors = { C.coral, C.grass, C.gold, C.berry }
for i, col in ipairs(logoColors) do
	local b = Instance.new("Frame")
	b.BackgroundColor3 = col
	b.Position = UDim2.fromOffset(14 + (i - 1) * 14, (HEADER_H - 12) / 2)
	b.Size = UDim2.fromOffset(12, 12)
	b.BorderSizePixel = 0
	b.ZIndex = 4
	b.Parent = Header
end

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, -160, 0, 20); TitleLabel.Position = UDim2.new(0, 78, 0, 4)
TitleLabel.BackgroundTransparency = 1; TitleLabel.Text = "BUILDBLOX"
TitleLabel.TextColor3 = C.textWhite; TitleLabel.Font = FONT
TitleLabel.TextSize = 20
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.ZIndex = 4; TitleLabel.Parent = Header

local SubtitleLabel = Instance.new("TextLabel")
SubtitleLabel.Size = UDim2.new(1, -160, 0, 14)
SubtitleLabel.Position = UDim2.new(0, 78, 0, HEADER_H - 18)
SubtitleLabel.BackgroundTransparency = 1
SubtitleLabel.Text = "HOW TO PLAY · BEGINNER GUIDE"
SubtitleLabel.TextColor3 = C.textMuted; SubtitleLabel.Font = FONT
SubtitleLabel.TextSize = 10
SubtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
SubtitleLabel.ZIndex = 4; SubtitleLabel.Parent = Header

-- Close button (top-right of panel)
local CLOSE_SIZE = 30
local CloseBtn = Instance.new("TextButton")
CloseBtn.Name = "CloseBtn"
CloseBtn.AnchorPoint = Vector2.new(1, 0.5)
CloseBtn.Position = UDim2.new(1, -8, 0.5, 0)
CloseBtn.Size = UDim2.fromOffset(CLOSE_SIZE, CLOSE_SIZE)
CloseBtn.BackgroundColor3 = C.closeBtn
CloseBtn.BorderSizePixel = 0
CloseBtn.Text = "X"
CloseBtn.TextColor3 = C.textWhite
CloseBtn.Font = FONT
CloseBtn.TextSize = 16
CloseBtn.ZIndex = 4
CloseBtn.AutoButtonColor = false
CloseBtn.Parent = Header
addBevel(CloseBtn, C.closeBtnHL, C.closeBtnSH)
CloseBtn.MouseEnter:Connect(function() CloseBtn.BackgroundColor3 = C.closeBtnHover end)
CloseBtn.MouseLeave:Connect(function() CloseBtn.BackgroundColor3 = C.closeBtn end)
CloseBtn.MouseButton1Down:Connect(function() CloseBtn.BackgroundColor3 = C.closeBtnPress end)
CloseBtn.MouseButton1Up:Connect(function() CloseBtn.BackgroundColor3 = C.closeBtnHover end)

-- ============================================
-- SIDEBAR TABS (parented to Wrapper, NOT Panel — so they can extend outside)
-- Tabs sit at x=-8 with width 86, so they reach from x=-8 to x=78.
-- PanelBg starts at x=58. So tabs overlap PanelBg by 20px on the right edge.
-- Tabs are placed BEFORE PanelBg in the tree (above in Wrapper.Parent order)
-- so PanelBg renders ON TOP of the overlapping tab portion.
-- ============================================
local TabContainer = Instance.new("Frame")
TabContainer.Name = "TabContainer"
if IsMobile then
	-- Tabs 56x56. Container 60 wide so tabs have 2px slack inside.
	-- 12px gap from the screen edge; PanelBg starts at x=72, so tabs end
	-- ~2px shy of it.
	TabContainer.Position = UDim2.new(0, 12, 0, 6)
	TabContainer.Size = UDim2.new(0, 60, 1, -12)
else
	-- Wrapper is 740 wide. PanelBg starts at x=58.
	-- Tabs are 76 wide. We want the right edge of tabs to land ~20px inside
	-- PanelBg (i.e. at x=78), so tab.left = 78 - 76 = 2.
	TabContainer.Position = UDim2.new(0, 2, 0, 38)
	TabContainer.Size = UDim2.new(0, 76, 1, -42)
end
TabContainer.BackgroundTransparency = 1
TabContainer.BorderSizePixel = 0
TabContainer.Parent = Wrapper

-- CRITICAL: move TabContainer to render BEFORE PanelBg in sibling order so
-- PanelBg's ZIndex.Sibling rendering naturally covers the tucked portion.
TabContainer.ZIndex = 0
-- Force TabContainer to be drawn first by re-parenting PanelBg AFTER it
PanelBg.Parent = nil
PanelBg.Parent = Wrapper

local tabLayout = Instance.new("UIListLayout")
tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout.FillDirection = Enum.FillDirection.Vertical
tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
tabLayout.VerticalAlignment = IsMobile and Enum.VerticalAlignment.Top or Enum.VerticalAlignment.Center
tabLayout.Padding = UDim.new(0, 4)
tabLayout.Parent = TabContainer

-- Each tab matches inventory category buttons: 76x56 desktop, 42x42 mobile.
-- The icon area shows a real block viewport (matching inventory categories).
local function createTab(label, accent, iconBlock, iconFolder, idx, iconOpts)
	local btnW = IsMobile and 56 or 76
	local btnH = IsMobile and 56 or 56

	local btn = Instance.new("TextButton")
	btn.Name = "Tab_" .. label
	btn.Size = UDim2.new(0, btnW, 0, btnH)
	btn.BackgroundColor3 = C.surface
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.ZIndex = 0
	btn.LayoutOrder = idx
	btn.Parent = TabContainer

	local bevels = addBevel(btn, C.bevelHL, C.bevelSH, 2)

	local ICON = IsMobile and 40 or 48
	local iconHolder = Instance.new("Frame")
	iconHolder.BackgroundTransparency = 1
	if IsMobile then
		iconHolder.Position = UDim2.new(0.5, -ICON/2, 0.5, -ICON/2)
	else
		iconHolder.Position = UDim2.new(0, 4, 0.5, -ICON/2)
	end
	iconHolder.Size = UDim2.fromOffset(ICON, ICON)
	iconHolder.ZIndex = btn.ZIndex + 1
	iconHolder.Parent = btn

	if iconBlock and iconFolder then
		local opts = iconOpts or {}
		createBlockViewport(iconHolder, UDim2.new(1, 0, 1, 0),
			iconBlock, iconFolder, opts.color, opts.material, opts.isTool, opts.leatherTint)
	else
		local solid = Instance.new("Frame")
		solid.BackgroundColor3 = accent
		solid.Size = UDim2.fromScale(1, 1)
		solid.BorderSizePixel = 0
		solid.ZIndex = iconHolder.ZIndex
		solid.Parent = iconHolder
	end

	tabBevels[idx] = bevels
	tabAccents[idx] = accent
	return btn
end

-- Wood color for crafting table (template ships uncolored). leatherTint colors
-- the Decals/Textures on the Side/Top faces so the tool-layout art reads as
-- wood-on-wood instead of bright bare textures.
local OAK_WOOD = {
	color = Color3.fromRGB(166, 124, 78),
	material = Enum.Material.WoodPlanks,
	leatherTint = Color3.fromRGB(165, 85, 38),
}

tabButtons[1] = createTab("BASICS", C.grass, "GrassBlock", "Blocks", 1)
tabButtons[2] = createTab("INVENTORY", C.berry, "CraftingTable", "BlockTemplates", 2, OAK_WOOD)
tabButtons[3] = createTab("ADVANCED", C.sky, "FrameBlock", "FrameBlocks", 3)
tabButtons[4] = createTab("NATURE", C.grass, "OakSapling", "Decorations", 4)

-- ============================================
-- TAB TOOLTIP (matches inventory style)
-- ============================================
local TabTooltip = Instance.new("Frame")
TabTooltip.Name = "TabTooltip"
TabTooltip.Size = UDim2.fromOffset(0, 0)
TabTooltip.AutomaticSize = Enum.AutomaticSize.XY
-- AnchorPoint Y=0.5 lets the position formula center the tooltip on the tab
-- middle without needing to know the tooltip's auto-sized height.
TabTooltip.AnchorPoint = Vector2.new(0, 0.5)
TabTooltip.BackgroundColor3 = Color3.fromRGB(16, 0, 16)
TabTooltip.BorderSizePixel = 0
TabTooltip.Visible = false
TabTooltip.ZIndex = 100
TabTooltip.Parent = Wrapper  -- parent to Wrapper so positions stay in the same coordinate space as the tabs
local ttStroke = Instance.new("UIStroke")
ttStroke.Color = Color3.fromRGB(40, 0, 80); ttStroke.Thickness = 2
ttStroke.Parent = TabTooltip
local ttInner = Instance.new("Frame")
ttInner.Size = UDim2.new(1, -4, 1, -4); ttInner.Position = UDim2.new(0, 2, 0, 2)
ttInner.BackgroundColor3 = Color3.fromRGB(16, 0, 16); ttInner.BorderSizePixel = 0
ttInner.ZIndex = 101; ttInner.Parent = TabTooltip
local ttInnerStroke = Instance.new("UIStroke")
ttInnerStroke.Color = Color3.fromRGB(80, 0, 160); ttInnerStroke.Thickness = 1
ttInnerStroke.Parent = ttInner
local ttText = Instance.new("TextLabel")
ttText.AutomaticSize = Enum.AutomaticSize.XY; ttText.BackgroundTransparency = 1
ttText.Text = ""; ttText.TextColor3 = Color3.fromRGB(255, 255, 255)
ttText.TextSize = 13; ttText.Font = FONT; ttText.ZIndex = 102
ttText.Parent = ttInner
local ttPad = Instance.new("UIPadding")
ttPad.PaddingLeft = UDim.new(0, 6); ttPad.PaddingRight = UDim.new(0, 6)
ttPad.PaddingTop = UDim.new(0, 4); ttPad.PaddingBottom = UDim.new(0, 4)
ttPad.Parent = ttInner

local tabLabels = { "BASICS", "INVENTORY", "ADVANCED", "NATURE" }
for i, tab in ipairs(tabButtons) do
	tab.MouseEnter:Connect(function()
		if not IsMobile then
			ttText.Text = tabLabels[i]
			local pos = tab.AbsolutePosition
			local sz = tab.AbsoluteSize
			local wpos = Wrapper.AbsolutePosition
			-- Subtract Wrapper's position to get coords in Wrapper's local space.
			TabTooltip.Position = UDim2.new(0, pos.X - wpos.X + sz.X + 8, 0, pos.Y - wpos.Y + sz.Y / 2)
			TabTooltip.Visible = true
		end
	end)
	tab.MouseLeave:Connect(function()
		TabTooltip.Visible = false
	end)
end

-- ============================================
-- BODY (scrolling content in main panel)
-- ============================================
-- Recessed inner area (matches inventory PresetsContainer treatment):
-- inset bevel + slightly darker bg so the cards visually sit in a sunken
-- well framed by the raised outer panel.
local RecessedArea = Instance.new("Frame")
RecessedArea.Name = "RecessedArea"
RecessedArea.Position = UDim2.new(0, 8, 0, HEADER_H + 6)
RecessedArea.Size = UDim2.new(1, -16, 1, -HEADER_H - 14)
RecessedArea.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
RecessedArea.BorderSizePixel = 0
RecessedArea.ZIndex = 2
RecessedArea.ClipsDescendants = true
RecessedArea.Parent = Panel
-- Inverted bevel = inset (shadow on top/left, highlight on bottom/right)
addBevel(RecessedArea, C.bevelSH, C.bevelHL, 3)

local Body = Instance.new("ScrollingFrame")
Body.Name = "Body"
-- Inset by 3px (the recessed area's bevel size) so scrolling content gets
-- clipped at the inner edge of the bevel instead of rendering over it.
Body.Position = UDim2.new(0, 3, 0, 3)
Body.Size = UDim2.new(1, -6, 1, -6)
Body.BackgroundTransparency = 1
Body.BorderSizePixel = 0
Body.CanvasSize = UDim2.fromScale(0, 0)
Body.AutomaticCanvasSize = Enum.AutomaticSize.Y
Body.ScrollBarThickness = 0
Body.ScrollingDirection = Enum.ScrollingDirection.Y
Body.ZIndex = 3
Body.Parent = RecessedArea

local bodyPad = Instance.new("UIPadding")
bodyPad.PaddingTop = UDim.new(0, 12); bodyPad.PaddingBottom = UDim.new(0, 12)
bodyPad.PaddingLeft = UDim.new(0, 14); bodyPad.PaddingRight = UDim.new(0, 14)
bodyPad.Parent = Body

local function createPage()
	local page = Instance.new("Frame")
	page.Name = "Page"
	page.BackgroundTransparency = 1
	-- X: -28 offset bypasses the Roblox ScrollingFrame + AutomaticCanvasSize.Y
	-- quirk where UIPadding.PaddingRight isn't fully applied to children's relative width.
	-- Y: AutomaticSize collapses the page to fit its actual content (no dead
	-- space at the bottom). Safe here because all children (sections, rows,
	-- cards, tips) are fixed-size — no AutomaticSize cascade to compound bugs.
	page.Size = UDim2.new(1, -28, 0, 0)
	page.AutomaticSize = Enum.AutomaticSize.Y
	page.Visible = false
	page.ZIndex = 4
	page.Parent = Body
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.Padding = UDim.new(0, 10)
	layout.Parent = page
	return page
end

-- ============================================
-- CARD ROW (2-column layout)
-- ============================================
-- Returns the height a card would have, without creating it. Used by
-- createCardRow to equalize heights across cards in the same row.
local function computeCardHeight(body, controlsText)
	local hasControls = controlsText ~= nil
	local bodyLines = math.ceil(#body / 40)
	local bodyH = math.max(20, bodyLines * 16)
	local titleH = 24
	local controlsH = hasControls and 20 or 0
	local gap1 = 4
	local gap2 = 4
	local contentH = titleH + gap1 + bodyH + (hasControls and (gap2 + controlsH) or 0)
	return contentH + 14 * 2
end

-- Pairs cards into a horizontal row. Cards are equalized to the tallest
-- card's height; controls are bottom-aligned so they land at the same Y
-- across the row regardless of body length. Extra height on shorter cards
-- becomes empty space between body and controls (intentional).
local function createCardRow(parent, layoutOrder, ...)
	local defs = {...}
	local maxH = 0
	for _, def in ipairs(defs) do
		local h = computeCardHeight(def[3], def[4])
		if h > maxH then maxH = h end
	end

	local row = Instance.new("Frame")
	row.Name = "CardRow"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, maxH)
	row.LayoutOrder = layoutOrder
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	for i, def in ipairs(defs) do
		local card = createCard(def[1], def[2], def[3], def[4], row, def[5], maxH)
		card.LayoutOrder = i
	end

	return row
end

-- ============================================
-- PAGE 1: BASICS
-- ============================================
do
	local page = createPage()
	pages[1] = page

	local sec1 = createSectionLabel("MOVEMENT", C.grass, "GrassBlock", "Blocks", page)
	sec1.LayoutOrder = 1

	createCardRow(page, 2,
		{1, "Walk", "Move around your plot.", "PC: WASD  |  Mobile: JOYSTICK", C.grass},
		{2, "Jump", "Hop onto blocks or over gaps.", "PC: SPACE  |  Mobile: JUMP BTN", C.grass}
	)
	createCardRow(page, 3,
		{3, "Sprint", "Hold to run faster.", "PC: CTRL  |  Mobile: SPRINT BTN", C.grass},
		{4, "Fly", "Double-tap jump to take off. Again to land.", "PC: SPACE SPACE  |  Mobile: 2x JUMP", C.grass}
	)

	local sec2 = createSectionLabel("BUILDING", C.wood, "OakPlanks", "Blocks", page)
	sec2.LayoutOrder = 4

	createCardRow(page, 5,
		{5, "Place a Block",
			"Aim where you want it, then click. The block snaps to the nearest grid space.",
			"PC: RIGHT CLICK  |  Mobile: TAP", C.wood},
		{6, "Break a Block",
			"Hold to break the block you're aiming at. The longer you hold, the further you'll break.",
			"PC: HOLD LEFT CLICK  |  Mobile: TAP & HOLD", C.wood}
	)

	local tip = createTip("Fly = Faster Building",
		"Flying makes tall builds way easier - double-tap jump to start, again to land.", page)
	tip.LayoutOrder = 6
end

-- ============================================
-- PAGE 2: INVENTORY & TOOLS
-- ============================================
do
	local page = createPage()
	pages[2] = page

	local sec1 = createSectionLabel("INVENTORY", C.berry, "CraftingTable", "BlockTemplates", page, OAK_WOOD)
	sec1.LayoutOrder = 1

	createCardRow(page, 2,
		{1, "Open Inventory", "Browse every block you own.", "PC: E  |  Mobile: INVENTORY BTN", C.berry},
		{2, "Add to Hotbar", "Tap any block in the menu to slot it.", "PC: CLICK  |  Mobile: TAP", C.berry}
	)
	createCardRow(page, 3,
		{3, "Remove from Hotbar", "Clear a slot to make room.", "PC: RIGHT CLICK or Q  |  Mobile: TAP & HOLD", C.berry},
		{4, "Move Between Inventories", "Transfer to chests, furnaces, crafting tables.", "PC: SHIFT + CLICK", C.berry}
	)

	local sec2 = createSectionLabel("TOOLS", C.sky, "Shovel", "Tools", page, { isTool = true })
	sec2.LayoutOrder = 4

	createCardRow(page, 5,
		{5, "Shovel",
			"Right-click a grass block to turn it into a smooth path block. Perfect for garden paths and dirt trails through your builds.",
			"PC: RIGHT CLICK grass  |  Mobile: TAP grass", C.sky},
		{6, "Shears",
			"Right-click a vine to stop its growth. Where you shear matters - shearing the top stops upward growth; shearing the bottom stops it from extending downward.",
			"PC: RIGHT CLICK vine  |  Mobile: TAP vine", C.sky}
	)
end

-- ============================================
-- PAGE 3: ADVANCED
-- ============================================
do
	local page = createPage()
	pages[3] = page

	local sec1 = createSectionLabel("SMART PLACEMENT", C.sky, "OakPlanks", "Blocks", page)
	sec1.LayoutOrder = 1

	createCardRow(page, 2,
		{1, "Slabs: Flat or Standing",
			"Where your crosshair lands on the block decides how the slab faces. Aim at the top or bottom for a flat slab; aim at a side for a vertical one. Use this for walls, steps, ledges, and tabletops from the same block.",
			nil, C.sky},
		{2, "Doors: Six Positions per Block",
			"Doors snap to the left or right side of the block you're aiming at - AND to the front, middle, or back of that side. That's 6 possible positions per block, so doors line up perfectly with walls of any thickness.",
			nil, C.sky}
	)
	createCardRow(page, 3,
		{3, "Fences: Toggle Wall Attachment",
			"Fences auto-connect to neighbors. If you don't want a fence reaching into a wall, right-click it to unattach. Right-click again to reattach.",
			"PC: RIGHT CLICK the fence  |  Mobile: TAP the fence", C.sky}
	)

	local sec2 = createSectionLabel("FRAME BLOCKS", C.gold, "FrameBlock", "FrameBlocks", page)
	sec2.LayoutOrder = 4

	createCardRow(page, 5,
		{4, "Place the Frame",
			"Frame blocks start as empty wireframes. Place them anywhere just like a regular block.",
			nil, C.gold},
		{5, "Fill With Any Texture",
			"Once a frame is placed, aim at any solid block in your world and right-click it. The frame copies that block's texture - give frames the look of stone, wood, glass, anything.",
			"PC: RIGHT CLICK a solid block  |  Mobile: TAP a solid block", C.gold}
	)
	createCardRow(page, 6,
		{6, "Wallpaper Frames",
			"A flat variant of frame blocks. Place them in any orientation - floors, walls, ceilings, sloped surfaces. They can intersect themselves at corners, and you can still place regular blocks on top of them.",
			nil, C.gold}
	)

	local tip = createTip("Why Use Frames?",
		"Mix textures freely without owning every block pack - perfect for creating new aesthetics.", page)
	tip.LayoutOrder = 7
end

-- ============================================
-- PAGE 4: NATURE
-- ============================================
do
	local page = createPage()
	pages[4] = page

	local sec1 = createSectionLabel("PLANTING TREES", C.grass, "OakSapling", "Decorations", page)
	sec1.LayoutOrder = 1

	createCardRow(page, 2,
		{1, "Big Trees Need Space",
			"Redwood and Dark Oak saplings only grow when planted in a 2x2 square - 4 of the same type placed next to each other. Other trees grow from a single sapling.",
			nil, C.grass}
	)
end

-- ============================================
-- TAB / PAGE LOGIC
-- ============================================
local function showPage(idx)
	currentPage = ((idx - 1) % #pages) + 1
	if currentPage < 1 then currentPage = #pages end

	for i, page in ipairs(pages) do
		page.Visible = (i == currentPage)
	end
	for i, tab in ipairs(tabButtons) do
		if i == currentPage then
			-- Active: match panel bg, lift in front so it appears "selected"
			tab.BackgroundColor3 = C.panelBg
			if tabBevels[i] then setBevel(tabBevels[i], C.bevelHL, C.bevelSH) end
		else
			tab.BackgroundColor3 = C.surface
			if tabBevels[i] then setBevel(tabBevels[i], C.bevelHL, C.bevelSH) end
		end
	end
	Body.CanvasPosition = Vector2.new(0, 0)
end

for i, tab in ipairs(tabButtons) do
	tab.MouseButton1Click:Connect(function()
		showPage(i)
	end)
	tab.MouseEnter:Connect(function()
		if currentPage ~= i then
			tab.BackgroundColor3 = C.surfaceHover
		end
	end)
	tab.MouseLeave:Connect(function()
		if currentPage ~= i then
			tab.BackgroundColor3 = C.surface
		end
	end)
end

-- ============================================
-- OPEN / CLOSE
-- ============================================
local helpBlur = Instance.new("BlurEffect")
helpBlur.Name = "HelpBookBlur"; helpBlur.Size = 0; helpBlur.Enabled = false
helpBlur.Parent = Lighting

local GAME_UIS_TO_HIDE = {
	"InventoryGui",
	"CrosshairGui",
	"MainMenuButtonGui",
	"CoinHUD",
	"HelpBookButtonGui",
	"TipToastsGui",
	"MobileControlsGui",
	"LikesLeaderboardGui",
	"FeedbackUI",
	"ChatMonitorUI",
}

local function hideGameUIs()
	for _, name in ipairs(GAME_UIS_TO_HIDE) do
		local ui = PlayerGui:FindFirstChild(name)
		if ui then ui.Enabled = false end
	end
	pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false) end)
end

local function showGameUIs()
	for _, name in ipairs(GAME_UIS_TO_HIDE) do
		local ui = PlayerGui:FindFirstChild(name)
		if ui then ui.Enabled = true end
	end
	pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true) end)
end

local function openBook()
	if IsOpen then return end
	if _G.CameraController and _G.CameraController.IsGameStarted and not _G.CameraController.IsGameStarted() then return end
	if _G.ShopUI and _G.ShopUI.IsOpen and _G.ShopUI.IsOpen() then return end
	if _G.DailyRewardsUI and _G.DailyRewardsUI.IsOpen and _G.DailyRewardsUI.IsOpen() then return end

	print(LOG_PREFIX, "Opening")
	IsOpen = true
	hideGameUIs()

	helpBlur.Size = 0; helpBlur.Enabled = true
	TweenService:Create(helpBlur, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = 20 }):Play()

	showPage(1)

	ScreenGui.Enabled = true
	local fullSize = panelSize
	Wrapper.Size = UDim2.new(
		fullSize.X.Scale * 0.88, fullSize.X.Offset * 0.88,
		fullSize.Y.Scale * 0.88, fullSize.Y.Offset * 0.88
	)
	Overlay.BackgroundTransparency = 1
	TweenService:Create(Wrapper, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = fullSize,
	}):Play()
	TweenService:Create(Overlay, TweenInfo.new(0.2), { BackgroundTransparency = 0.4 }):Play()
end

local function closeBook()
	if not IsOpen then return end
	print(LOG_PREFIX, "Closing")
	IsOpen = false

	TweenService:Create(helpBlur, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = 0 }):Play()

	local fullSize = panelSize
	local tp = TweenService:Create(Wrapper, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = UDim2.new(
			fullSize.X.Scale * 0.92, fullSize.X.Offset * 0.92,
			fullSize.Y.Scale * 0.92, fullSize.Y.Offset * 0.92
		),
	})
	local to = TweenService:Create(Overlay, TweenInfo.new(0.15), { BackgroundTransparency = 1 })
	tp:Play(); to:Play(); tp.Completed:Wait()
	ScreenGui.Enabled = false
	Wrapper.Size = fullSize
	helpBlur.Enabled = false

	showGameUIs()
end

local function toggleBook()
	if IsOpen then closeBook() else openBook() end
end

CloseBtn.MouseButton1Click:Connect(closeBook)

Overlay.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		closeBook()
	end
end)
ClickCatcher.MouseButton1Click:Connect(closeBook)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if UserInputService:GetFocusedTextBox() then return end
	if input.KeyCode == Enum.KeyCode.B then
		toggleBook()
	elseif IsOpen and (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.Q) then
		closeBook()
	end
end)

_G.HelpBookUI.Open = openBook
_G.HelpBookUI.Close = closeBook
_G.HelpBookUI.Toggle = toggleBook

print(LOG_PREFIX, "Initialized - Press B to open")
