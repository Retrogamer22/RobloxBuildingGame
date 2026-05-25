--[[
	PlusUI.client.luau

	Modal panel describing Roblox Plus benefits, with a single Subscribe CTA
	(or an "Active" state when the player already has Plus).

	Opens via:
	  - Top-bar PlusButton (PlusButtonGui)
	  - Main menu PlusButton on the title screen
	  - Any other code calling _G.PlusUI.Open() / Toggle()

	Cursor-lock: registered via _G.PlusUI.IsOpen and added to CameraController's
	isAnyUIOpen list — without that, mouse stays locked while the modal is open.

	Styling: sky-blue cardboard cloud aesthetic that fits the game's room/plot
	look. Beveled Minecraft frames consistent with the rest of BuildBlox's UI.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local LOG_PREFIX = "[BB-PLUS-UI]"

local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local FONT = Enum.Font.Arcade
local FONT_BODY = Enum.Font.Gotham
local FONT_BOLD = Enum.Font.GothamBold
local BEVEL = 2

-- ============================================
-- THEME (sky-blue / cardboard cloud)
-- ============================================
local C = {
	-- Panel
	panelBg = Color3.fromRGB(32, 70, 110),       -- deep sky-blue, leans toward cardboard navy
	panelBevelHL = Color3.fromRGB(72, 130, 180),
	panelBevelSH = Color3.fromRGB(14, 30, 50),

	-- Header
	headerBg = Color3.fromRGB(48, 102, 158),
	headerBevelHL = Color3.fromRGB(96, 162, 216),
	headerBevelSH = Color3.fromRGB(20, 50, 80),

	-- Inner recessed area (where the perk cards live)
	recessedBg = Color3.fromRGB(22, 50, 80),
	recessedBevelHL = Color3.fromRGB(60, 110, 156),
	recessedBevelSH = Color3.fromRGB(8, 22, 36),

	-- Perk cards
	cardBg = Color3.fromRGB(56, 116, 170),
	cardBevelHL = Color3.fromRGB(108, 174, 226),
	cardBevelSH = Color3.fromRGB(20, 56, 90),

	-- Card variants by perk type
	cardGoldBg = Color3.fromRGB(140, 100, 30),     -- Robux perk
	cardGoldHL = Color3.fromRGB(220, 170, 50),
	cardGoldSH = Color3.fromRGB(70, 50, 14),

	cardCoinBg = Color3.fromRGB(120, 86, 24),      -- BloxCoin perk (slightly different gold)
	cardCoinHL = Color3.fromRGB(200, 150, 40),
	cardCoinSH = Color3.fromRGB(60, 42, 10),

	cardLockBg = Color3.fromRGB(80, 90, 120),      -- Private servers perk
	cardLockHL = Color3.fromRGB(140, 156, 192),
	cardLockSH = Color3.fromRGB(34, 40, 60),

	cardSendBg = Color3.fromRGB(60, 130, 90),      -- Robux transfers perk
	cardSendHL = Color3.fromRGB(120, 200, 150),
	cardSendSH = Color3.fromRGB(22, 60, 38),

	-- Subscribe button (vibrant gold so it pops against the sky-blue panel)
	ctaBg = Color3.fromRGB(244, 196, 48),
	ctaBgHover = Color3.fromRGB(255, 220, 80),
	ctaBgPress = Color3.fromRGB(200, 160, 30),
	ctaBevelHL = Color3.fromRGB(255, 232, 130),
	ctaBevelSH = Color3.fromRGB(130, 100, 20),
	ctaText = Color3.fromRGB(40, 30, 10),

	-- Active-badge (subscriber state)
	activeBg = Color3.fromRGB(76, 175, 80),
	activeBevelHL = Color3.fromRGB(140, 220, 140),
	activeBevelSH = Color3.fromRGB(30, 80, 30),
	activeText = Color3.fromRGB(255, 255, 255),

	-- Close (X)
	closeBtn = Color3.fromRGB(180, 50, 50),
	closeBtnHover = Color3.fromRGB(210, 70, 70),
	closeBtnPress = Color3.fromRGB(140, 35, 35),
	closeBtnHL = Color3.fromRGB(220, 100, 100),
	closeBtnSH = Color3.fromRGB(100, 30, 30),

	-- Text
	textWhite = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(206, 222, 240),
	textMuted = Color3.fromRGB(140, 162, 188),
	textDarkOnGold = Color3.fromRGB(50, 36, 8),
	textGold = Color3.fromRGB(244, 196, 48),

	-- Special highlight for "tier 2 unlocked" indicator
	tierActiveBg = Color3.fromRGB(64, 142, 76),
	tierActiveHL = Color3.fromRGB(120, 200, 130),
	tierActiveSH = Color3.fromRGB(28, 70, 36),

	overlay = Color3.fromRGB(0, 0, 0),
}

-- ============================================
-- STATE
-- ============================================
-- (Plus state is read from _G.PlusController, which now holds the single
-- DEBUG_FORCE_STATE switch that drives every Plus UI.)
local IsOpen = false
local OpenedFromTitle = false

_G.PlusUI = {
	IsOpen = function() return IsOpen end,
}

-- ============================================
-- HELPERS
-- ============================================
local function addBevel(frame, hlColor, shColor, bevelSize)
	local hl = hlColor or C.panelBevelHL
	local sh = shColor or C.panelBevelSH
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
-- ROOT GUI
-- ============================================
-- Clean up any leftover instances from previous script runs.
for _, existing in ipairs(PlayerGui:GetChildren()) do
	if existing.Name == "PlusUI" then existing:Destroy() end
end
for _, existing in ipairs(Lighting:GetChildren()) do
	if existing.Name == "PlusUIBlur" then existing:Destroy() end
end

-- Two ScreenGuis on purpose:
--  - OverlayGui uses IgnoreGuiInset = true so the dim + click-catcher cover the
--    WHOLE screen edge-to-edge (otherwise, under CoreUISafeInsets, the dim would
--    only fill the safe area and read as a boxy dark rectangle in the middle).
--  - ScreenGui (the panel) uses CoreUISafeInsets so the panel auto-stays below
--    the system topbar. Separating them gives full-bleed dimming AND a safe panel.
local OverlayGui = Instance.new("ScreenGui")
OverlayGui.Name = "PlusUIOverlay"; OverlayGui.ResetOnSpawn = false
OverlayGui.DisplayOrder = 24  -- one under the panel GUI
OverlayGui.IgnoreGuiInset = true
OverlayGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
OverlayGui.Enabled = false; OverlayGui.Parent = PlayerGui

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "PlusUI"; ScreenGui.ResetOnSpawn = false
-- ScreenInsets = CoreUISafeInsets lets the ENGINE keep this GUI inside the safe
-- area automatically — below the system topbar (hamburger/chat/gear) and clear
-- of notches/rounded corners — across every device. This replaces the old
-- IgnoreGuiInset + manual GetGuiInset shift, which had to be hand-tuned per
-- screen and still clipped the header on short landscape phones.
ScreenGui.DisplayOrder = 25
ScreenGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Enabled = false; ScreenGui.Parent = PlayerGui

-- Full-screen dim, lives in the inset-ignoring OverlayGui so it bleeds to every edge.
local Overlay = Instance.new("Frame")
Overlay.Name = "Overlay"
Overlay.Size = UDim2.new(1, 0, 1, 0)
Overlay.BackgroundColor3 = C.overlay
Overlay.BackgroundTransparency = 1
Overlay.BorderSizePixel = 0
Overlay.ZIndex = 1
Overlay.Active = false
Overlay.Parent = OverlayGui

-- Dedicated click-catcher behind the panel for outside-click-to-close. Also in
-- the full-screen OverlayGui so taps anywhere outside the panel dismiss it.
local ClickCatcher = Instance.new("TextButton")
ClickCatcher.Name = "ClickCatcher"
ClickCatcher.Size = UDim2.new(1, 0, 1, 0)
ClickCatcher.BackgroundTransparency = 1
ClickCatcher.BorderSizePixel = 0
ClickCatcher.Text = ""
ClickCatcher.AutoButtonColor = false
ClickCatcher.ZIndex = 1
ClickCatcher.Parent = OverlayGui

-- ============================================
-- PANEL
-- ============================================
-- Mobile sizing is driven by HEIGHT (Y scale) only; the UIAspectRatioConstraint
-- on the Panel derives the width from it (1.35:1), so the modal keeps the same
-- proportions on a wide landscape phone and a tall one alike — no stretching.
-- 0.9 of the safe-area height fills it comfortably with a small margin. The
-- width scale here is a fallback only; the aspect constraint overrides it.
-- Desktop keeps its fixed 580x520 pixel size (no constraint applied there).
local panelW = IsMobile and 0.9 or 580
-- Desktop height trimmed from 520 -> 340 to fit the content (header + 2x2 grid +
-- CTA) snugly instead of leaving a big empty gap below SUBSCRIBE. Mobile is
-- driven by the aspect constraint, so its 0.9 here is just a fallback.
local panelH = IsMobile and 0.9 or 340
local panelSize = IsMobile and UDim2.new(panelW, 0, panelH, 0)
	or UDim2.new(0, panelW, 0, panelH)

local Panel = Instance.new("Frame")
Panel.Name = "Panel"
Panel.AnchorPoint = Vector2.new(0.5, 0.5)
-- Dead-centered in the safe area. No manual inset shift needed — ScreenInsets =
-- CoreUISafeInsets (above) makes (0.5, 0.5) mean the center of the area BELOW
-- the topbar, so the header is automatically clear of the system icons.
Panel.Position = UDim2.new(0.5, 0, 0.5, 0)
Panel.Size = panelSize
Panel.BackgroundColor3 = C.panelBg
Panel.BorderSizePixel = 0
Panel.Active = true   -- consume clicks so they don't bubble to ClickCatcher
Panel.ZIndex = 2
Panel.Parent = ScreenGui
-- Lock the panel's shape so scale-only sizing can't stretch it into a cramped
-- rectangle on wide landscape phones vs tall ones. The panel sizes from screen
-- height (Y scale) and the constraint derives the width, so it reads the same
-- on every aspect ratio. AspectType ScaleWithParentSize keeps it within the
-- viewport. (Mobile only; desktop keeps its fixed 580x520 offset size.)
if IsMobile then
	local panelAspect = Instance.new("UIAspectRatioConstraint")
	-- 2.5:1 — extra-wide landscape modal. The added WIDTH lets each half-width
	-- perk card's body text wrap in fewer lines, so the cards can be SLIMMER
	-- (shorter) while still keeping everything inside the recessed bevel.
	panelAspect.AspectRatio = 2.5
	panelAspect.DominantAxis = Enum.DominantAxis.Height
	panelAspect.AspectType = Enum.AspectType.ScaleWithParentSize
	panelAspect.Parent = Panel
end
addBevel(Panel, C.panelBevelHL, C.panelBevelSH, 3)

-- ============================================
-- HEADER
-- ============================================
local HEADER_H = IsMobile and 54 or 60

local Header = Instance.new("Frame")
Header.Name = "Header"
Header.Size = UDim2.new(1, 0, 0, HEADER_H)
Header.BackgroundColor3 = C.headerBg
Header.BorderSizePixel = 0
Header.ZIndex = 3
Header.Parent = Panel
addBevel(Header, C.headerBevelHL, C.headerBevelSH, 3)

-- Plus brand block — a chunky gold "+" inside a sky-blue tile, mirroring
-- the top-bar PlusButton icon so the header reads as the same brand.
local LOGO_SIZE = HEADER_H - 16

local logoTile = Instance.new("Frame")
logoTile.Name = "LogoTile"
logoTile.Position = UDim2.new(0, 12, 0.5, 0)
logoTile.AnchorPoint = Vector2.new(0, 0.5)
logoTile.Size = UDim2.new(0, LOGO_SIZE, 0, LOGO_SIZE)
logoTile.BackgroundColor3 = Color3.fromRGB(76, 155, 230)
logoTile.BorderSizePixel = 0
logoTile.ZIndex = 4
logoTile.Parent = Header
addBevel(logoTile, Color3.fromRGB(140, 200, 255), Color3.fromRGB(48, 112, 188), 2)

local logoIcon = Instance.new("TextLabel")
logoIcon.Name = "LogoIcon"
logoIcon.AnchorPoint = Vector2.new(0.5, 0.5)
logoIcon.Position = UDim2.new(0.5, 0, 0.5, 0)
logoIcon.Size = UDim2.new(1, 0, 1, 0)
logoIcon.BackgroundTransparency = 1
logoIcon.Text = utf8.char(0xE003)  -- official Roblox Plus glyph (matches top-bar icon)
logoIcon.TextColor3 = Color3.fromRGB(255, 255, 255)
logoIcon.Font = Enum.Font.GothamBold
logoIcon.TextSize = math.floor(LOGO_SIZE * 0.7)
logoIcon.ZIndex = 5
logoIcon.Parent = logoTile

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, -(LOGO_SIZE + 28 + 100), 0, 22)
TitleLabel.Position = UDim2.new(0, LOGO_SIZE + 24, 0, 8)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "ROBLOX PLUS"
TitleLabel.TextColor3 = C.textWhite
TitleLabel.Font = FONT
TitleLabel.TextSize = IsMobile and 18 or 22
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.BorderSizePixel = 0
TitleLabel.ZIndex = 4
TitleLabel.Parent = Header

local SubtitleLabel = Instance.new("TextLabel")
SubtitleLabel.Name = "Subtitle"
SubtitleLabel.Size = UDim2.new(1, -(LOGO_SIZE + 28 + 100), 0, 16)
SubtitleLabel.Position = UDim2.new(0, LOGO_SIZE + 24, 0, HEADER_H - 24)
SubtitleLabel.BackgroundTransparency = 1
SubtitleLabel.Text = "More for your Robux, in BuildBlox + everywhere"
SubtitleLabel.TextColor3 = C.textMuted
SubtitleLabel.Font = FONT_BODY
SubtitleLabel.TextSize = IsMobile and 10 or 11
SubtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
SubtitleLabel.ZIndex = 4
SubtitleLabel.Parent = Header

-- Close (X) at top-right
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
local closeBevels = addBevel(CloseBtn, C.closeBtnHL, C.closeBtnSH)
CloseBtn.MouseEnter:Connect(function() CloseBtn.BackgroundColor3 = C.closeBtnHover end)
CloseBtn.MouseLeave:Connect(function() CloseBtn.BackgroundColor3 = C.closeBtn end)
CloseBtn.MouseButton1Down:Connect(function() CloseBtn.BackgroundColor3 = C.closeBtnPress end)
CloseBtn.MouseButton1Up:Connect(function() CloseBtn.BackgroundColor3 = C.closeBtnHover end)

-- "ACTIVE" badge (hidden until we confirm the player has Plus). Sits to the
-- left of the close button so it reads at a glance.
local activeBadgeW = 88
local ActiveBadge = Instance.new("Frame")
ActiveBadge.Name = "ActiveBadge"
ActiveBadge.AnchorPoint = Vector2.new(1, 0.5)
ActiveBadge.Position = UDim2.new(1, -(CLOSE_SIZE + 16), 0.5, 0)
ActiveBadge.Size = UDim2.fromOffset(activeBadgeW, 28)
ActiveBadge.BackgroundColor3 = C.activeBg
ActiveBadge.BorderSizePixel = 0
ActiveBadge.Visible = false
ActiveBadge.ZIndex = 4
ActiveBadge.Parent = Header
addBevel(ActiveBadge, C.activeBevelHL, C.activeBevelSH, 2)
local ActiveBadgeLabel = Instance.new("TextLabel")
ActiveBadgeLabel.Size = UDim2.new(1, 0, 1, 0)
ActiveBadgeLabel.BackgroundTransparency = 1
ActiveBadgeLabel.Text = "★ ACTIVE"
ActiveBadgeLabel.TextColor3 = C.activeText
ActiveBadgeLabel.Font = FONT
ActiveBadgeLabel.TextSize = 14
ActiveBadgeLabel.ZIndex = 5
ActiveBadgeLabel.Parent = ActiveBadge

-- ============================================
-- BODY
-- ============================================
-- Recessed inner area framing the perk list and the CTA. Inverted bevel for
-- the inset look (shadow on top/left, highlight on bottom/right), same trick
-- HelpBookUI uses.
local BodyHolder = Instance.new("Frame")
BodyHolder.Name = "BodyHolder"
BodyHolder.Position = UDim2.new(0, 10, 0, HEADER_H + 8)
BodyHolder.Size = UDim2.new(1, -20, 1, -HEADER_H - 16)
BodyHolder.BackgroundColor3 = C.recessedBg
BodyHolder.BorderSizePixel = 0
BodyHolder.ZIndex = 2
BodyHolder.Parent = Panel
addBevel(BodyHolder, C.recessedBevelSH, C.recessedBevelHL, 3)

local BodyPadding = Instance.new("UIPadding")
BodyPadding.PaddingTop = UDim.new(0, 12)
BodyPadding.PaddingBottom = UDim.new(0, 12)
BodyPadding.PaddingLeft = UDim.new(0, 14)
BodyPadding.PaddingRight = UDim.new(0, 14)
BodyPadding.Parent = BodyHolder

-- All body content (section label, perk cards, CTA) lives in this group. It's
-- TOP-anchored and fills the padded body width so it stays INSIDE the recessed
-- bevel. (It used to be center-anchored + auto-height, which let a tall content
-- block overflow equally past the top AND bottom bevel.)
local Group = Instance.new("Frame")
Group.Name = "BodyGroup"
Group.AnchorPoint = Vector2.new(0.5, 0)
Group.Position = UDim2.new(0.5, 0, 0, 0)
-- Full padded width MINUS a side inset, so the perk grid (which fills this
-- group) sits in from the recessed bevel on the left and right instead of
-- running edge-to-edge. Full padded height so content lays out within the bevel.
Group.Size = UDim2.new(1, IsMobile and -24 or -28, 1, 0)
Group.BackgroundTransparency = 1
Group.ZIndex = 3
Group.Parent = BodyHolder

local groupLayout = Instance.new("UIListLayout")
groupLayout.FillDirection = Enum.FillDirection.Vertical
groupLayout.SortOrder = Enum.SortOrder.LayoutOrder
groupLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
groupLayout.VerticalAlignment = Enum.VerticalAlignment.Top
-- Tighter vertical rhythm on mobile so section label + 2x2 grid + CTA fit on
-- short landscape screens without the bottom button clipping past the bevel.
groupLayout.Padding = UDim.new(0, IsMobile and 8 or 12)
groupLayout.Parent = Group

-- "WHAT YOU GET" section label. Nudged right a touch (PaddingLeft) and given
-- a shorter height so it sits closer to the cards below it.
local SectionLabel = Instance.new("TextLabel")
SectionLabel.Name = "SectionLabel"
SectionLabel.Size = UDim2.new(1, 0, 0, 18)
SectionLabel.BackgroundTransparency = 1
SectionLabel.Text = "WHAT YOU GET"
SectionLabel.TextColor3 = C.textGold
SectionLabel.Font = FONT
SectionLabel.TextSize = IsMobile and 14 or 16
SectionLabel.TextXAlignment = Enum.TextXAlignment.Left
SectionLabel.ZIndex = 4
SectionLabel.LayoutOrder = 1
SectionLabel.Parent = Group
local SectionLabelPad = Instance.new("UIPadding")
SectionLabelPad.PaddingLeft = UDim.new(0, 6)
SectionLabelPad.Parent = SectionLabel

-- ============================================
-- PERK CARDS
-- Each card: small icon-tile on the left + title + body text on the right.
-- We track each card so applyPlusState() can highlight the "BuildBlox 10%
-- BloxCoin discount" card differently when the player is/isn't subscribed,
-- and bump the labels from "10%" -> "20%" when they hit tier 2.
-- ============================================
local CARD_H = IsMobile and 48 or 56
local ICON_TILE = IsMobile and 32 or 40
local CARDS_TOP_Y = 22 + 6  -- below section label

-- Perk cards are arranged in a 2-COLUMN GRID (2x2 for the four perks) rather
-- than a single tall stack. With the wide panel (aspect 2.1) each half-width
-- cell is roomy horizontally, so the body wraps to few lines and the cells can
-- be SHORT — keeping the whole block (label + grid + CTA) inside the bevel.
local GRID_CARD_H = IsMobile and 52 or 60
local GRID_GAP = IsMobile and 8 or 10

-- Cards live inside this stack (now a 2-col GRID). Created here, BEFORE
-- makePerkCard, so the card factory can parent into it. (Lua closures capture
-- the local at definition time — declaring Stack *after* the factory made the
-- factory see a nil global instead, which is why every card piled up at 0,0
-- on top of each other.)
local Stack = Instance.new("Frame")
Stack.Name = "Stack"
Stack.BackgroundTransparency = 1
Stack.Size = UDim2.new(1, 0, 0, 0)          -- height auto-fits the grid rows
Stack.AutomaticSize = Enum.AutomaticSize.Y
Stack.LayoutOrder = 2
Stack.ZIndex = 3
Stack.Parent = Group

-- 2-column grid. CellSize width = half the Stack width minus half the gap, so
-- two cards + one gap exactly fill the row. CellPadding adds the gap between
-- columns and rows. SortOrder = LayoutOrder keeps the cards in their 1-4 order
-- (coin, rewards, lock, robux) flowing left-to-right, top-to-bottom.
local stackLayout = Instance.new("UIGridLayout")
stackLayout.FillDirection = Enum.FillDirection.Horizontal
stackLayout.SortOrder = Enum.SortOrder.LayoutOrder
stackLayout.CellSize = UDim2.new(0.5, -math.floor(GRID_GAP / 2), 0, GRID_CARD_H)
stackLayout.CellPadding = UDim2.fromOffset(GRID_GAP, GRID_GAP)
stackLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
stackLayout.Parent = Stack

-- Green "unlocked" check chip overlaid on a perk card's icon tile when the
-- player is subscribed, so each perk visibly reads as active. Tracked in
-- cardChecks; toggled from applyState.
local cardChecks = {}
local function makeActiveCheck(parent)
	local dot = Instance.new("Frame")
	dot.Name = "ActiveCheck"
	dot.Size = UDim2.fromOffset(16, 16)
	dot.AnchorPoint = Vector2.new(1, 0)
	dot.Position = UDim2.new(1, 3, 0, -3)  -- pokes out the icon tile's top-right corner
	dot.BackgroundColor3 = Color3.fromRGB(76, 175, 80)
	dot.BorderSizePixel = 0
	dot.Visible = false
	dot.ZIndex = parent.ZIndex + 6
	dot.Parent = parent
	addBevel(dot, Color3.fromRGB(150, 220, 150), Color3.fromRGB(40, 100, 40), 1)
	local check = Instance.new("TextLabel")
	check.Size = UDim2.fromScale(1, 1)
	check.BackgroundTransparency = 1
	check.Text = "\u{2713}"
	check.TextColor3 = Color3.fromRGB(255, 255, 255)
	check.Font = FONT_BOLD
	check.TextSize = 12
	check.ZIndex = dot.ZIndex + 1
	check.Parent = dot
	return dot
end

local function makeIconTile(parent, bg, bevelHL, bevelSH, glyphMaker)
	local tile = Instance.new("Frame")
	tile.Size = UDim2.new(0, ICON_TILE, 0, ICON_TILE)
	-- Left edge, vertically centered — the wide short cells use a horizontal
	-- layout (icon on the left, title+body stacked to its right).
	tile.Position = UDim2.new(0, 8, 0.5, 0)
	tile.AnchorPoint = Vector2.new(0, 0.5)
	tile.BackgroundColor3 = bg
	tile.BorderSizePixel = 0
	tile.ZIndex = 5
	tile.Parent = parent
	addBevel(tile, bevelHL, bevelSH, 2)
	if glyphMaker then glyphMaker(tile) end
	return tile
end

-- Glyph builders — kept inline as functions so the card list below is
-- compact and we don't accumulate dozens of one-off variables.
local function glyphRobux(tile)
	-- Roblox's Robux glyph character. Falls back to "R$" if the font doesn't
	-- render it on a given platform.
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = utf8.char(0xE002)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = FONT_BOLD
	label.TextSize = math.floor(ICON_TILE * 0.62)
	label.ZIndex = tile.ZIndex + 2
	label.Parent = tile
end

local function glyphBloxCoin(tile)
	-- Shopping-bags emoji — this perk is about the BloxCoin SHOP, so a shop
	-- icon reads the intent better than a bare "B" currency mark. (The other
	-- cards use emoji glyphs too: gift, lock, so this stays visually consistent.)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "\u{1F6CD}"  -- 🛍️ shopping bags
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = FONT_BODY
	label.TextSize = math.floor(ICON_TILE * 0.6)
	label.ZIndex = tile.ZIndex + 2
	label.Parent = tile
end

local function glyphLock(tile)
	-- Clean padlock glyph rendered as a character (crisper than hand-built
	-- frames at this small tile size).
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "\u{1F512}"  -- 🔒
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = FONT_BODY
	label.TextSize = math.floor(ICON_TILE * 0.62)
	label.ZIndex = tile.ZIndex + 2
	label.Parent = tile
end

local function glyphSend(tile)
	-- Paper-plane glyph as a character — reads cleaner than the rotated-frame
	-- triangle at small sizes.
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "\u{2708}"  -- ✈
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = FONT_BODY
	label.TextSize = math.floor(ICON_TILE * 0.58)
	label.ZIndex = tile.ZIndex + 2
	label.Parent = tile
end

local function glyphGift(tile)
	-- Gift/present glyph for the "bigger daily rewards" perk.
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "\u{1F381}"  -- 🎁
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = FONT_BODY
	label.TextSize = math.floor(ICON_TILE * 0.6)
	label.ZIndex = tile.ZIndex + 2
	label.Parent = tile
end

-- Card factory. Returns the card frame plus a couple of named child labels
-- we'll need to mutate later (title for the % tier, body if we want to
-- annotate active state).
local function makePerkCard(layoutOrder, opts)
	local card = Instance.new("Frame")
	card.Name = "Card_" .. opts.id
	-- Size is controlled by the parent UIGridLayout (CellSize); no explicit size.
	card.BackgroundColor3 = opts.bg
	card.BorderSizePixel = 0
	card.LayoutOrder = layoutOrder
	card.ZIndex = 4
	card.Parent = Stack
	local bevels = addBevel(card, opts.bevelHL, opts.bevelSH, 2)

	-- Wide short cells: icon on the LEFT (vertically centered), with the title on
	-- top and the body text just below it, both to the right of the icon. Uses the
	-- cell's generous WIDTH instead of height.
	local iconTile = makeIconTile(card, opts.iconBg, opts.iconBevelHL, opts.iconBevelSH, opts.glyph)
	table.insert(cardChecks, makeActiveCheck(iconTile))

	local titleLbl = Instance.new("TextLabel")
	titleLbl.Name = "Title"
	titleLbl.BackgroundTransparency = 1
	titleLbl.Position = UDim2.new(0, ICON_TILE + 16, 0, IsMobile and 6 or 8)
	titleLbl.Size = UDim2.new(1, -(ICON_TILE + 24), 0, IsMobile and 15 or 17)
	titleLbl.Font = FONT
	titleLbl.Text = opts.title
	titleLbl.TextColor3 = C.textWhite
	titleLbl.TextSize = IsMobile and 13 or 15
	titleLbl.TextXAlignment = Enum.TextXAlignment.Left
	titleLbl.TextYAlignment = Enum.TextYAlignment.Top
	titleLbl.TextTruncate = Enum.TextTruncate.AtEnd
	titleLbl.ZIndex = 5
	titleLbl.Parent = card

	local bodyLbl = Instance.new("TextLabel")
	bodyLbl.Name = "Body"
	bodyLbl.BackgroundTransparency = 1
	-- Body starts just below the title, to the right of the icon, and fills the
	-- remaining width + height of the cell.
	bodyLbl.Position = UDim2.new(0, ICON_TILE + 16, 0, IsMobile and 23 or 27)
	bodyLbl.Size = UDim2.new(1, -(ICON_TILE + 24), 1, -(IsMobile and 28 or 33))
	bodyLbl.Font = FONT_BODY
	bodyLbl.Text = opts.body
	bodyLbl.TextColor3 = C.textDim
	bodyLbl.TextSize = IsMobile and 11 or 12
	bodyLbl.TextWrapped = true
	bodyLbl.TextXAlignment = Enum.TextXAlignment.Left
	bodyLbl.TextYAlignment = Enum.TextYAlignment.Top
	bodyLbl.ZIndex = 5
	bodyLbl.Parent = card

	-- Small "BuildBlox exclusive" pill on the right side for the BloxCoin
	-- card — emphasizes it's a perk we layer on top of Roblox's.
	if opts.exclusivePill then
		local pill = Instance.new("Frame")
		pill.Size = UDim2.fromOffset(IsMobile and 92 or 104, 18)
		pill.AnchorPoint = Vector2.new(1, 0)
		pill.Position = UDim2.new(1, -8, 0, 8)
		pill.BackgroundColor3 = Color3.fromRGB(76, 155, 230)
		pill.BorderSizePixel = 0
		pill.ZIndex = 6
		pill.Parent = card
		addBevel(pill, Color3.fromRGB(140, 200, 255), Color3.fromRGB(48, 112, 188), 1)
		local pillLbl = Instance.new("TextLabel")
		pillLbl.Size = UDim2.fromScale(1, 1)
		pillLbl.BackgroundTransparency = 1
		pillLbl.Text = "BUILDBLOX"
		pillLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
		pillLbl.Font = FONT
		pillLbl.TextSize = 10
		pillLbl.ZIndex = 7
		pillLbl.Parent = pill
	end

	return card, titleLbl, bodyLbl
end

-- The four perk cards, ordered BuildBlox-first: the in-game perks (BloxCoin
-- discount, bigger daily rewards) lead, then the broader Roblox perks (free
-- private servers, Robux discount). The Robux + BloxCoin cards have tier-aware
-- title/body text that we update from applyState (10% → 20%).
local coinCard, coinTitle, coinBody = makePerkCard(1, {
	id = "coin",
	bg = C.cardCoinBg, bevelHL = C.cardCoinHL, bevelSH = C.cardCoinSH,
	iconBg = C.cardCoinBg, iconBevelHL = C.cardCoinHL, iconBevelSH = C.cardCoinSH,
	glyph = glyphBloxCoin,
	title = "10% off the BloxCoin shop",
	body = "Save on every block pack, mod, and save slot in BuildBlox. Rises to 20% after 3 months.",
})

local rewardsCard = makePerkCard(2, {
	id = "rewards",
	bg = C.cardSendBg, bevelHL = C.cardSendHL, bevelSH = C.cardSendSH,
	iconBg = C.cardSendBg, iconBevelHL = C.cardSendHL, iconBevelSH = C.cardSendSH,
	glyph = glyphGift,
	title = "Bigger daily rewards",
	body = "Earn extra BloxCoins from your daily login streak — build up to premium content faster.",
})

local lockCard = makePerkCard(3, {
	id = "lock",
	bg = C.cardLockBg, bevelHL = C.cardLockHL, bevelSH = C.cardLockSH,
	iconBg = C.cardLockBg, iconBevelHL = C.cardLockHL, iconBevelSH = C.cardLockSH,
	glyph = glyphLock,
	title = "Free private servers",
	body = "Host your own private BuildBlox server free — plus every other paid Roblox game.",
})

local robuxCard, robuxTitle, robuxBody = makePerkCard(4, {
	id = "robux",
	bg = C.cardGoldBg, bevelHL = C.cardGoldHL, bevelSH = C.cardGoldSH,
	iconBg = C.cardGoldBg, iconBevelHL = C.cardGoldHL, iconBevelSH = C.cardGoldSH,
	glyph = glyphRobux,
	title = "10% off Robux purchases",
	body = "Cheaper Robux on every BuildBlox pack — and anywhere on Roblox. Rises to 20% after 3 months.",
})

-- ============================================
-- CTA AREA (bottom of body)
-- Subscribe button when not subscribed, status message when subscribed.
-- ============================================
local CTA_H = IsMobile and 40 or 46
local CTA_PADDING_BOTTOM = 4

local CTAFrame = Instance.new("Frame")
CTAFrame.Name = "CTAFrame"
CTAFrame.Size = UDim2.new(1, 0, 0, CTA_H)
CTAFrame.BackgroundTransparency = 1
CTAFrame.LayoutOrder = 3
CTAFrame.ZIndex = 4
CTAFrame.Parent = Group

local SubscribeBtn = Instance.new("TextButton")
SubscribeBtn.Name = "SubscribeBtn"
SubscribeBtn.AnchorPoint = Vector2.new(0.5, 0.5)
SubscribeBtn.Position = UDim2.new(0.5, 0, 0.5, 0)
SubscribeBtn.Size = UDim2.new(0.62, 0, 1, -8)
SubscribeBtn.BackgroundColor3 = C.ctaBg
SubscribeBtn.BorderSizePixel = 0
SubscribeBtn.Text = ""  -- text is in stacked child labels below
SubscribeBtn.AutoButtonColor = false
SubscribeBtn.ZIndex = 5
SubscribeBtn.Parent = CTAFrame
local subscribeBevels = addBevel(SubscribeBtn, C.ctaBevelHL, C.ctaBevelSH, 3)

-- Stacked label: big "SUBSCRIBE" over a smaller price line, so the button
-- can be shorter without cramming everything on one wide row.
local subscribeMain = Instance.new("TextLabel")
subscribeMain.Name = "Main"
subscribeMain.BackgroundTransparency = 1
subscribeMain.Position = UDim2.new(0, 0, 0, IsMobile and 4 or 5)
subscribeMain.Size = UDim2.new(1, 0, 0, IsMobile and 18 or 20)
subscribeMain.Text = "SUBSCRIBE"
subscribeMain.TextColor3 = C.ctaText
subscribeMain.Font = FONT
subscribeMain.TextSize = IsMobile and 16 or 19
subscribeMain.ZIndex = 6
subscribeMain.Parent = SubscribeBtn

local subscribePrice = Instance.new("TextLabel")
subscribePrice.Name = "Price"
subscribePrice.BackgroundTransparency = 1
subscribePrice.Position = UDim2.new(0, 0, 1, IsMobile and -16 or -17)
subscribePrice.Size = UDim2.new(1, 0, 0, IsMobile and 13 or 14)
subscribePrice.Text = "$4.99 / month"
subscribePrice.TextColor3 = C.ctaText
subscribePrice.TextTransparency = 0.15
subscribePrice.Font = FONT_BODY
subscribePrice.TextSize = IsMobile and 11 or 12
subscribePrice.ZIndex = 6
subscribePrice.Parent = SubscribeBtn

SubscribeBtn.MouseEnter:Connect(function()
	SubscribeBtn.BackgroundColor3 = C.ctaBgHover
end)
SubscribeBtn.MouseLeave:Connect(function()
	SubscribeBtn.BackgroundColor3 = C.ctaBg
	setBevel(subscribeBevels, C.ctaBevelHL, C.ctaBevelSH)
end)
SubscribeBtn.MouseButton1Down:Connect(function()
	SubscribeBtn.BackgroundColor3 = C.ctaBgPress
	setBevel(subscribeBevels, C.ctaBevelSH, C.ctaBevelHL)
end)
SubscribeBtn.MouseButton1Up:Connect(function()
	SubscribeBtn.BackgroundColor3 = C.ctaBgHover
	setBevel(subscribeBevels, C.ctaBevelHL, C.ctaBevelSH)
end)

-- Replaces SubscribeBtn when the player already has Plus. Shows tier +
-- subscriber-since info instead of a CTA.
local SubscribedInfo = Instance.new("Frame")
SubscribedInfo.Name = "SubscribedInfo"
SubscribedInfo.AnchorPoint = Vector2.new(0.5, 0.5)
SubscribedInfo.Position = UDim2.new(0.5, 0, 0.5, 0)
SubscribedInfo.Size = UDim2.new(1, -16, 1, -8)
SubscribedInfo.BackgroundColor3 = C.tierActiveBg
SubscribedInfo.BorderSizePixel = 0
SubscribedInfo.Visible = false
SubscribedInfo.ZIndex = 5
SubscribedInfo.Parent = CTAFrame
addBevel(SubscribedInfo, C.tierActiveHL, C.tierActiveSH, 3)

local SubscribedTitle = Instance.new("TextLabel")
SubscribedTitle.Size = UDim2.new(1, -16, 0, 20)
SubscribedTitle.Position = UDim2.new(0, 8, 0, 6)
SubscribedTitle.BackgroundTransparency = 1
SubscribedTitle.Text = "★ PLUS ACTIVE — TIER 1 (10% OFF)"
SubscribedTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
SubscribedTitle.Font = FONT
SubscribedTitle.TextSize = IsMobile and 14 or 16
SubscribedTitle.ZIndex = 6
SubscribedTitle.Parent = SubscribedInfo

local SubscribedBody = Instance.new("TextLabel")
SubscribedBody.Size = UDim2.new(1, -16, 0, 18)
SubscribedBody.Position = UDim2.new(0, 8, 0, 28)
SubscribedBody.BackgroundTransparency = 1
SubscribedBody.Text = "Thanks for supporting BuildBlox!"
SubscribedBody.TextColor3 = Color3.fromRGB(218, 240, 220)
SubscribedBody.Font = FONT_BODY
SubscribedBody.TextSize = IsMobile and 11 or 12
SubscribedBody.ZIndex = 6
SubscribedBody.Parent = SubscribedInfo

-- ============================================
-- APPLY STATE
-- Adjusts the CTA + perk-card text to reflect current Plus status.
-- ============================================
local function fmtPercent(n)
	return tostring(n) .. "%"
end

local function applyState()
	local controller = _G.PlusController
	local subscribed = false
	local percent = 10
	local startUnix = nil
	if controller then
		subscribed = controller.IsSubscribed and controller.IsSubscribed() or false
		percent = (controller.GetDiscountPercent and controller.GetDiscountPercent()) or 0
		startUnix = controller.GetSubStartUnix and controller.GetSubStartUnix() or nil
	end

	-- Per-card "unlocked" checks + section heading reflect ownership.
	for _, chk in ipairs(cardChecks) do
		chk.Visible = subscribed
	end
	SectionLabel.Text = subscribed and "YOUR ACTIVE PERKS" or "WHAT YOU GET"

	-- Cards always show the current tier the player WOULD get (or HAS gotten).
	-- If not subscribed, default messaging is "10%" — that's what they unlock first.
	local displayPercent = subscribed and percent or 10
	robuxTitle.Text = string.format("%s off Robux purchases", fmtPercent(displayPercent))
	coinTitle.Text = string.format("%s off the BloxCoin shop", fmtPercent(displayPercent))

	-- If they're already at tier 2, body text drops the "rises to 20%" note
	-- (it's redundant) and just says it's their current rate.
	if subscribed and percent >= 20 then
		robuxBody.Text = "20% cheaper Robux on every BuildBlox pack — and anywhere on Roblox. Your max tier."
		coinBody.Text = "20% off every block pack, mod, and save slot in BuildBlox. Your max tier."
	else
		robuxBody.Text = "Cheaper Robux on every BuildBlox pack — and anywhere on Roblox. Rises to 20% after 3 months."
		coinBody.Text = "Save on every block pack, mod, and save slot in BuildBlox. Rises to 20% after 3 months."
	end

	if subscribed then
		ActiveBadge.Visible = true
		SubscribeBtn.Visible = false
		SubscribedInfo.Visible = true
		SubtitleLabel.Text = "Thanks for supporting BuildBlox + Roblox!"

		-- Tier 1 vs Tier 2 messaging on the bottom info card.
		if percent >= 20 then
			SubscribedTitle.Text = "★ PLUS ACTIVE  ·  TIER 2 (20% OFF)"
		else
			SubscribedTitle.Text = "★ PLUS ACTIVE  ·  TIER 1 (10% OFF)"
		end

		if startUnix then
			-- Format as a friendly "Subscriber since Apr 30, 2026" line.
			local subDate = os.date("!*t", startUnix)
			local months = {
				"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec",
			}
			local dateStr = string.format("%s %d, %d", months[subDate.month], subDate.day, subDate.year)
			if percent < 20 then
				-- How many days until they hit tier 2? Helps motivate retention.
				local daysSubbed = math.floor((os.time() - startUnix) / 86400)
				local daysUntilT2 = math.max(0, 60 - daysSubbed)
				if daysUntilT2 > 0 then
					SubscribedBody.Text = string.format("Subscriber since %s — %d days until 20%% tier", dateStr, daysUntilT2)
				else
					SubscribedBody.Text = string.format("Subscriber since %s", dateStr)
				end
			else
				SubscribedBody.Text = string.format("Subscriber since %s", dateStr)
			end
		else
			SubscribedBody.Text = "Thanks for supporting BuildBlox!"
		end
	else
		ActiveBadge.Visible = false
		SubscribeBtn.Visible = true
		SubscribedInfo.Visible = false
		SubtitleLabel.Text = "More for your Robux, in BuildBlox + everywhere"
	end
end

-- ============================================
-- SUBSCRIBE BUTTON ACTION
-- ============================================
SubscribeBtn.MouseButton1Click:Connect(function()
	if _G.PlusController and _G.PlusController.PromptPurchase then
		print(LOG_PREFIX, "User clicked Subscribe — requesting prompt")
		_G.PlusController.PromptPurchase()
		-- Tiny visual feedback: swap the main label to OPENING and hide the price
		-- briefly so a player who keeps clicking before the Roblox prompt animates
		-- in doesn't think it's broken.
		subscribeMain.Text = "OPENING…"
		subscribePrice.Visible = false
		task.delay(2, function()
			subscribeMain.Text = "SUBSCRIBE"
			subscribePrice.Visible = true
			applyState()
		end)
	end
end)

-- ============================================
-- OPEN / CLOSE
-- ============================================
local plusBlur = Instance.new("BlurEffect")
plusBlur.Name = "PlusUIBlur"; plusBlur.Size = 0; plusBlur.Enabled = false
plusBlur.Parent = Lighting

-- UIs to hide when PlusUI is open (mirrors HelpBookUI's list).
local GAME_UIS_TO_HIDE = {
	"InventoryGui",
	"CrosshairGui",
	"MainMenuButtonGui",
	"CoinHUD",
	"HelpBookButtonGui",
	"PlusButtonGui",
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

-- DETERMINISTIC HUD SUPPRESSION (replaces the old "hide once + re-hide 6 times"
-- loop, which was a RACE: whether our hide "won" depended on timing vs each
-- HUD's own controller re-enabling itself, so HUDs flashed/stuck inconsistently).
--
-- Instead, while the panel is open we LISTEN to each GUI's Enabled property and
-- force it back to false the instant anything flips it on. No polling, no timing
-- luck — if a controller re-enables its HUD, the change fires our handler in the
-- same frame and we immediately re-hide it. Listeners are torn down on close.
local suppressConns = {}        -- active GetPropertyChangedSignal connections
local suppressChildAddedConn    -- catches HUDs that load LATE (after we open)
local suppressing = false

local function suppressOne(ui)
	-- Hide now, and keep it hidden: any later flip to Enabled = true is undone.
	ui.Enabled = false
	suppressConns[ui] = ui:GetPropertyChangedSignal("Enabled"):Connect(function()
		if suppressing and ui.Enabled then
			ui.Enabled = false
		end
	end)
end

local function startSuppressGameUIs()
	suppressing = true
	for _, name in ipairs(GAME_UIS_TO_HIDE) do
		local ui = PlayerGui:FindFirstChild(name)
		if ui and not suppressConns[ui] then
			suppressOne(ui)
		end
	end
	-- A HUD ScreenGui that streams in AFTER we opened still gets suppressed.
	suppressChildAddedConn = PlayerGui.ChildAdded:Connect(function(child)
		if not suppressing then return end
		for _, name in ipairs(GAME_UIS_TO_HIDE) do
			if child.Name == name and not suppressConns[child] then
				suppressOne(child)
				break
			end
		end
	end)
	pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false) end)
end

local function stopSuppressGameUIs()
	suppressing = false
	if suppressChildAddedConn then
		suppressChildAddedConn:Disconnect()
		suppressChildAddedConn = nil
	end
	for ui, conn in pairs(suppressConns) do
		conn:Disconnect()
		if ui then ui.Enabled = true end   -- restore on close
	end
	suppressConns = {}
	pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true) end)
end

local function openPanel()
	if IsOpen then return end
	-- Same gating other modals respect — don't pop on top of another modal.
	if _G.ShopUI and _G.ShopUI.IsOpen and _G.ShopUI.IsOpen() then return end
	if _G.HelpBookUI and _G.HelpBookUI.IsOpen and _G.HelpBookUI.IsOpen() then return end
	if _G.DailyRewardsUI and _G.DailyRewardsUI.IsOpen and _G.DailyRewardsUI.IsOpen() then return end

	print(LOG_PREFIX, "Opening")
	IsOpen = true

	-- Funnel analytics: report every open (any source). The server throttles
	-- and sanitizes this, so it's safe to fire unconditionally here.
	if _G.PlusController and _G.PlusController.ReportOpened then
		_G.PlusController.ReportOpened(OpenedFromTitle and "title_screen" or "hud_button")
	end

	applyState()  -- so the panel never shows stale content

	if not OpenedFromTitle then
		startSuppressGameUIs()  -- hide HUDs and KEEP them hidden (deterministic, no race)
	end

	plusBlur.Size = 0; plusBlur.Enabled = true
	TweenService:Create(plusBlur, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = 20,
	}):Play()

	ScreenGui.Enabled = true
	OverlayGui.Enabled = true
	local fullSize = panelSize
	Panel.Size = UDim2.new(
		fullSize.X.Scale * 0.88, fullSize.X.Offset * 0.88,
		fullSize.Y.Scale * 0.88, fullSize.Y.Offset * 0.88
	)
	Overlay.BackgroundTransparency = 1
	TweenService:Create(Panel, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = fullSize,
	}):Play()
	TweenService:Create(Overlay, TweenInfo.new(0.2), { BackgroundTransparency = 0.4 }):Play()
end

local function closePanel()
	if not IsOpen then return end
	print(LOG_PREFIX, "Closing")
	IsOpen = false
	local wasFromTitle = OpenedFromTitle
	OpenedFromTitle = false

	TweenService:Create(plusBlur, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = 0,
	}):Play()

	local fullSize = panelSize
	local tp = TweenService:Create(Panel, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = UDim2.new(
			fullSize.X.Scale * 0.92, fullSize.X.Offset * 0.92,
			fullSize.Y.Scale * 0.92, fullSize.Y.Offset * 0.92
		),
	})
	local to = TweenService:Create(Overlay, TweenInfo.new(0.15), { BackgroundTransparency = 1 })
	tp:Play(); to:Play(); tp.Completed:Wait()
	ScreenGui.Enabled = false
	OverlayGui.Enabled = false
	Panel.Size = fullSize
	plusBlur.Enabled = false

	-- If we opened from the title screen, hand control back to it instead of
	-- restoring the in-game HUD.
	if wasFromTitle then
		if _G.TitleScreen and _G.TitleScreen.Show then
			_G.TitleScreen.Show()
		end
	else
		stopSuppressGameUIs()  -- tear down listeners and restore the HUDs
	end
end

local function togglePanel()
	if IsOpen then closePanel() else openPanel() end
end

CloseBtn.MouseButton1Click:Connect(closePanel)
Overlay.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		closePanel()
	end
end)
ClickCatcher.MouseButton1Click:Connect(closePanel)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if UserInputService:GetFocusedTextBox() then return end
	if IsOpen and (input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.Q) then
		closePanel()
	end
end)

-- ============================================
-- PUBLIC API
-- ============================================
_G.PlusUI.Open = openPanel
_G.PlusUI.Close = closePanel
_G.PlusUI.Toggle = togglePanel

-- Title-screen entry point — same pattern as ShopUI.OpenFromTitleScreen.
-- Skips the hideGameUIs() since the title screen has already hidden them
-- and we want to return to the title (not the game) on close.
_G.PlusUI.OpenFromTitleScreen = function()
	OpenedFromTitle = true
	openPanel()
end

-- ============================================
-- LIVE UPDATES FROM PLUSCONTROLLER
-- ============================================
task.spawn(function()
	for _ = 1, 30 do
		if _G.PlusController then break end
		task.wait(0.2)
	end
	if _G.PlusController and _G.PlusController.OnChanged then
		_G.PlusController.OnChanged(applyState)
	end
	applyState()
end)

print(LOG_PREFIX, "Initialized")
