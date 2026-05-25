--[[
	ShopUI.client.luau
	Minecraft Bedrock-style marketplace — single scrollable page
	Coin packs row at top, Mods section below (coming soon)
	Nearly fullscreen, dark MC theme
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")
local Lighting = game:GetService("Lighting")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local CoinConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("CoinConfig"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local GetCoinData = Remotes:WaitForChild("GetCoinData", 10)
local CoinBalanceUpdate = Remotes:WaitForChild("CoinBalanceUpdate", 10)

-- ============================================
-- CONFIG
-- ============================================
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local FONT = Enum.Font.Arcade
local FONT_SMALL = Enum.Font.Gotham
local ROBUX_ICON = utf8.char(0xE002)
local BEVEL = 2

local C = {
	panelBg = Color3.fromRGB(24, 20, 20),
	headerBg = Color3.fromRGB(50, 42, 42),
	bevelHL = Color3.fromRGB(60, 54, 54),
	bevelSH = Color3.fromRGB(14, 12, 12),

	sectionBg = Color3.fromRGB(30, 26, 26),
	sectionBevelHL = Color3.fromRGB(48, 42, 42),
	sectionBevelSH = Color3.fromRGB(16, 14, 14),

	cardBg = Color3.fromRGB(40, 36, 36),
	cardBevelHL = Color3.fromRGB(60, 54, 54),
	cardBevelSH = Color3.fromRGB(20, 16, 16),

	buyBtn = Color3.fromRGB(76, 175, 80),
	buyBtnHover = Color3.fromRGB(100, 200, 100),
	buyBtnPress = Color3.fromRGB(56, 140, 60),
	buyBtnBevelHL = Color3.fromRGB(120, 220, 140),
	buyBtnBevelSH = Color3.fromRGB(40, 100, 50),

	closeBtn = Color3.fromRGB(180, 50, 50),
	closeBtnHover = Color3.fromRGB(210, 70, 70),
	closeBtnPress = Color3.fromRGB(140, 35, 35),
	closeBtnBevelHL = Color3.fromRGB(220, 100, 100),
	closeBtnBevelSH = Color3.fromRGB(100, 30, 30),

	gold = Color3.fromRGB(255, 200, 50),
	goldDim = Color3.fromRGB(180, 140, 30),

	textWhite = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(170, 170, 170),
	textMuted = Color3.fromRGB(100, 95, 95),

	overlay = Color3.fromRGB(0, 0, 0),

	bonusBg = Color3.fromRGB(60, 50, 25),
	bonusText = Color3.fromRGB(255, 220, 100),
	bestValueBg = Color3.fromRGB(180, 50, 50),
	bestValueText = Color3.fromRGB(255, 255, 255),
}

local PACK_IMAGES = {
	pack_small  = "rbxassetid://92695934122431",
	pack_medium = "rbxassetid://91872635410788",
	pack_large  = "rbxassetid://108635316771806",
	pack_mega   = "rbxassetid://126240741960870",
}

-- ============================================
-- STATE
-- ============================================
local ShopOpen = false
local CurrentBalance = 0
local OpenedFromTitle = false

_G.ShopUI = {
	IsOpen = function() return ShopOpen end,
	OpenFromTitleScreen = nil,
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

local function addInsetBevel(frame, sh, hl, b)
	return addBevel(frame, sh or Color3.fromRGB(14, 12, 12), hl or Color3.fromRGB(55, 48, 48), b)
end

local function setBevel(bv, hl, sh)
	bv.top.BackgroundColor3 = hl; bv.left.BackgroundColor3 = hl
	bv.bottom.BackgroundColor3 = sh; bv.right.BackgroundColor3 = sh
end

local function makeMCButton(props)
	local btn = Instance.new("TextButton")
	btn.Name = props.name or "MCButton"
	btn.Size = props.size; btn.Position = props.position
	if props.anchorPoint then btn.AnchorPoint = props.anchorPoint end
	btn.BackgroundColor3 = props.color; btn.BorderSizePixel = 0
	btn.Text = props.text or ""; btn.TextColor3 = props.textColor or C.textWhite
	btn.Font = props.font or FONT; btn.TextSize = props.textSize or 14
	btn.ZIndex = props.zIndex or 5; btn.AutoButtonColor = false
	btn.Parent = props.parent
	local bevels = addBevel(btn, props.bevelHL, props.bevelSH, nil)
	btn.MouseEnter:Connect(function() btn.BackgroundColor3 = props.hoverColor or props.color end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = props.color; setBevel(bevels, props.bevelHL, props.bevelSH)
	end)
	btn.MouseButton1Down:Connect(function()
		btn.BackgroundColor3 = props.pressColor or props.color; setBevel(bevels, props.bevelSH, props.bevelHL)
	end)
	btn.MouseButton1Up:Connect(function()
		btn.BackgroundColor3 = props.hoverColor or props.color; setBevel(bevels, props.bevelHL, props.bevelSH)
	end)
	return btn, bevels
end

local function formatNumber(n)
	if n >= 1000000 then return string.format("%.1fM", n / 1000000)
	elseif n >= 10000 then return string.format("%.1fK", n / 1000)
	elseif n >= 1000 then
		local s = tostring(math.floor(n))
		return s:sub(1, #s - 3) .. "," .. s:sub(#s - 2)
	else return tostring(math.floor(n)) end
end

-- ============================================
-- ROBLOX PLUS DISCOUNT PREVIEW (accurate, API-driven)
-- ============================================
-- Roblox Plus members get 10-20% off Robux purchases, applied by Roblox at
-- the purchase prompt — creators still earn full price, so we never lower
-- pack pricing ourselves. To SHOW the right number we ask Roblox via
-- GetProductInfoAsync, which (called client-side) returns the local player's
-- user-specific pricing:
--   UserBasePriceInRobux = pre-discount base price (for the strikethrough)
--   PriceInRobux         = the actual price the player is charged at the prompt
-- Using Roblox's own number guarantees the preview matches the prompt exactly.
-- (Computing it ourselves drifted — e.g. Studio test purchases apply 20%, not
-- the 10% we'd guess from a fresh subscription.)
local function fetchProductPricing(productId)
	if not productId or productId == 0 then return nil, nil end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfoAsync(productId, Enum.InfoType.Product)
	end)
	if not ok or type(info) ~= "table" then return nil, nil end
	local final = tonumber(info.PriceInRobux)
	local base = tonumber(info.UserBasePriceInRobux) or final
	return base, final
end

-- Renders pricing for one card entry { btn, orig, productId, robux }.
-- When discounted (final < base): the struck-through base price shows on the
-- card's dark background (high contrast = readable, unlike on the green
-- button) and the button shows the discounted price in white. Otherwise the
-- button shows the single price and the strikethrough label hides.
local function renderCardPricing(entry, base, final)
	local btn, orig = entry.btn, entry.orig
	if not final then
		-- No live price (productId 0 or fetch failed) → plain configured value.
		orig.Visible = false
		btn.RichText = false
		btn.Text = ROBUX_ICON .. " " .. tostring(entry.robux)
		return
	end
	if base and final < base then
		orig.Visible = true
		orig.Text = string.format("<s>%s %d</s>", ROBUX_ICON, base)
		btn.RichText = false
		btn.Text = ROBUX_ICON .. " " .. tostring(final)
	else
		orig.Visible = false
		btn.RichText = false
		btn.Text = ROBUX_ICON .. " " .. tostring(final)
	end
end

-- Registry of coin pack cards { btn, orig, productId, robux }. Filled as the
-- cards are built; iterated by refreshAllPricing at the bottom of the script.
local coinPackCards = {}

-- ============================================
-- GUI
-- ============================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "ShopUI"; ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 20; ScreenGui.IgnoreGuiInset = true
ScreenGui.Enabled = false; ScreenGui.Parent = PlayerGui

local Overlay = Instance.new("Frame")
Overlay.Name = "Overlay"; Overlay.Size = UDim2.new(1, 0, 1, 0)
Overlay.BackgroundColor3 = C.overlay; Overlay.BackgroundTransparency = 1
Overlay.BorderSizePixel = 0; Overlay.ZIndex = 1; Overlay.Active = true
Overlay.Parent = ScreenGui

-- Panel: nearly fullscreen
local Panel = Instance.new("Frame")
Panel.Name = "ShopPanel"
Panel.Size = UDim2.new(IsMobile and 0.95 or 0.85, 0, IsMobile and 0.9 or 0.82, 0)
Panel.Position = UDim2.new(0.5, 0, 0.5, 0)
Panel.AnchorPoint = Vector2.new(0.5, 0.5)
Panel.BackgroundColor3 = C.panelBg; Panel.BackgroundTransparency = 0
Panel.BorderSizePixel = 0; Panel.ZIndex = 2; Panel.Active = true
Panel.Parent = ScreenGui
addBevel(Panel)

-- ============================================
-- HEADER
-- ============================================
local HEADER_H = IsMobile and 40 or 50

local Header = Instance.new("Frame")
Header.Name = "Header"; Header.Size = UDim2.new(1, 0, 0, HEADER_H)
Header.BackgroundColor3 = C.headerBg; Header.BorderSizePixel = 0
Header.ZIndex = 3; Header.Parent = Panel
addBevel(Header, C.bevelHL, C.bevelSH)

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, -80, 1, 0); TitleLabel.Position = UDim2.new(0, 14, 0, 0)
TitleLabel.BackgroundTransparency = 1; TitleLabel.Text = "SHOP"
TitleLabel.TextColor3 = C.textWhite; TitleLabel.Font = FONT
TitleLabel.TextSize = IsMobile and 20 or 26
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.ZIndex = 4; TitleLabel.Parent = Header

-- Balance
local BalanceFrame = Instance.new("Frame")
BalanceFrame.Size = UDim2.new(0, IsMobile and 110 or 140, 0, 28)
BalanceFrame.Position = UDim2.new(1, -(IsMobile and 155 or 195), 0.5, 0)
BalanceFrame.AnchorPoint = Vector2.new(0, 0.5)
BalanceFrame.BackgroundColor3 = Color3.fromRGB(30, 26, 26)
BalanceFrame.BorderSizePixel = 0; BalanceFrame.ZIndex = 4; BalanceFrame.Parent = Header
addInsetBevel(BalanceFrame, nil, nil, 1)

local MiniCoin = Instance.new("Frame")
MiniCoin.Size = UDim2.new(0, 18, 0, 18)
MiniCoin.Position = UDim2.new(0, 6, 0.5, 0); MiniCoin.AnchorPoint = Vector2.new(0, 0.5)
MiniCoin.BackgroundColor3 = C.gold; MiniCoin.BorderSizePixel = 0
MiniCoin.ZIndex = 5; MiniCoin.Parent = BalanceFrame
Instance.new("UICorner", MiniCoin).CornerRadius = UDim.new(1, 0)

local MCL = Instance.new("TextLabel")
MCL.Size = UDim2.new(1, 0, 1, 0); MCL.BackgroundTransparency = 1; MCL.Text = "B"
MCL.TextColor3 = Color3.fromRGB(180, 130, 20); MCL.Font = Enum.Font.GothamBold
MCL.TextScaled = true; MCL.ZIndex = 6; MCL.Parent = MiniCoin

local BalanceLabel = Instance.new("TextLabel")
BalanceLabel.Name = "BalanceText"; BalanceLabel.Size = UDim2.new(1, -30, 1, 0)
BalanceLabel.Position = UDim2.new(0, 28, 0, 0); BalanceLabel.BackgroundTransparency = 1
BalanceLabel.Text = "0"; BalanceLabel.TextColor3 = C.gold; BalanceLabel.Font = FONT
BalanceLabel.TextSize = IsMobile and 16 or 18
BalanceLabel.TextXAlignment = Enum.TextXAlignment.Left
BalanceLabel.ZIndex = 5; BalanceLabel.Parent = BalanceFrame

-- Close button
local CLOSE_SIZE = IsMobile and 36 or 38
local CloseBtn = makeMCButton({
	name = "CloseBtn", size = UDim2.new(0, CLOSE_SIZE, 0, CLOSE_SIZE),
	position = UDim2.new(1, -CLOSE_SIZE - 6, 0.5, 0), anchorPoint = Vector2.new(0, 0.5),
	color = C.closeBtn, hoverColor = C.closeBtnHover, pressColor = C.closeBtnPress,
	bevelHL = C.closeBtnBevelHL, bevelSH = C.closeBtnBevelSH,
	text = "X", textSize = IsMobile and 16 or 18,
	zIndex = 4, parent = Header,
})

-- ============================================
-- SCROLLABLE CONTENT (marketplace-style)
-- ============================================
local Scroll = Instance.new("ScrollingFrame")
Scroll.Name = "Content"
Scroll.Size = UDim2.new(1, -16, 1, -HEADER_H - 12)
Scroll.Position = UDim2.new(0, 8, 0, HEADER_H + 4)
Scroll.BackgroundTransparency = 1; Scroll.BorderSizePixel = 0
Scroll.ScrollBarThickness = IsMobile and 4 or 6
Scroll.ScrollBarImageColor3 = Color3.fromRGB(80, 70, 70)
Scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
Scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
Scroll.ScrollingDirection = Enum.ScrollingDirection.Y
Scroll.ZIndex = 3; Scroll.Parent = Panel

local ScrollLayout = Instance.new("UIListLayout")
ScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
ScrollLayout.Padding = UDim.new(0, 10)
ScrollLayout.Parent = Scroll

local ScrollPadding = Instance.new("UIPadding")
ScrollPadding.PaddingTop = UDim.new(0, 6)
ScrollPadding.PaddingBottom = UDim.new(0, 6)
ScrollPadding.Parent = Scroll

-- ============================================
-- SECTION: BLOX COINS
-- ============================================
local COIN_SECTION_H = IsMobile and 200 or 240

local coinSection = Instance.new("Frame")
coinSection.Name = "CoinSection"
coinSection.Size = UDim2.new(1, 0, 0, COIN_SECTION_H)
coinSection.BackgroundColor3 = C.sectionBg; coinSection.BorderSizePixel = 0
coinSection.ZIndex = 3; coinSection.LayoutOrder = 1; coinSection.Parent = Scroll
addBevel(coinSection, C.sectionBevelHL, C.sectionBevelSH)

-- Section header
local coinHeader = Instance.new("TextLabel")
coinHeader.Size = UDim2.new(1, 0, 0, 28)
coinHeader.Position = UDim2.new(0, 12, 0, 6)
coinHeader.BackgroundTransparency = 1; coinHeader.Text = "BloxCoins"
coinHeader.TextColor3 = C.gold; coinHeader.Font = FONT
coinHeader.TextSize = IsMobile and 16 or 20
coinHeader.TextXAlignment = Enum.TextXAlignment.Left
coinHeader.ZIndex = 4; coinHeader.Parent = coinSection

-- Coin cards container (horizontal row)
local CARD_TOP = 36
local CARD_PAD = IsMobile and 6 or 8
local CARD_COUNT = #CoinConfig.CoinPacks
local BUY_H = IsMobile and 32 or 36
local CARD_AREA_H = COIN_SECTION_H - CARD_TOP - 8

for idx, pack in ipairs(CoinConfig.CoinPacks) do
	local col = idx - 1

	local card = Instance.new("Frame")
	card.Name = "Card_" .. pack.id
	card.BackgroundColor3 = C.cardBg; card.BorderSizePixel = 0
	card.ZIndex = 4; card.Parent = coinSection

	if IsMobile then
		card.Size = UDim2.new(0.5, -CARD_PAD * 1.5, 0.5, -CARD_PAD - 4)
		local r = math.floor(col / 2)
		local c = col % 2
		card.Position = UDim2.new(
			c * 0.5, CARD_PAD + c * CARD_PAD * 0.5,
			0, CARD_TOP + r * (CARD_AREA_H / 2 + CARD_PAD * 0.5)
		)
	else
		-- 4 across
		card.Size = UDim2.new(0.25, -CARD_PAD * 1.25, 0, CARD_AREA_H)
		card.Position = UDim2.new(col * 0.25, CARD_PAD + col * CARD_PAD * 0.25, 0, CARD_TOP)
	end

	addBevel(card, C.cardBevelHL, C.cardBevelSH)

	-- Badge
	if pack.bonus then
		local badgeBg = (pack.bonus == "Best Value") and C.bestValueBg or C.bonusBg
		local badgeText = (pack.bonus == "Best Value") and C.bestValueText or C.bonusText
		local badge = Instance.new("Frame"); badge.Name = "Badge"
		badge.Size = UDim2.new(0, IsMobile and 65 or 80, 0, IsMobile and 15 or 18)
		badge.Position = UDim2.new(1, -(IsMobile and 69 or 84), 0, 4)
		badge.BackgroundColor3 = badgeBg; badge.BorderSizePixel = 0; badge.ZIndex = 7; badge.Parent = card
		local bl = Instance.new("TextLabel"); bl.Size = UDim2.new(1, 0, 1, 0)
		bl.BackgroundTransparency = 1; bl.Text = pack.bonus; bl.TextColor3 = badgeText
		bl.Font = FONT; bl.TextSize = IsMobile and 8 or 10; bl.ZIndex = 8; bl.Parent = badge
	end

	-- Coin image (height trimmed a touch to leave room for the struck-through
	-- original price line that appears above the button when discounted)
	local coinImage = Instance.new("ImageLabel"); coinImage.Name = "CoinImage"
	coinImage.Size = UDim2.new(1, -10, 1, -BUY_H - 28)
	coinImage.Position = UDim2.new(0, 5, 0, 4)
	coinImage.BackgroundTransparency = 1; coinImage.Image = PACK_IMAGES[pack.id] or ""
	coinImage.ScaleType = Enum.ScaleType.Fit
	coinImage.ZIndex = 5; coinImage.Parent = card

	-- Struck-through original price. Lives on the card's dark background (NOT
	-- on the green button) so it stays readable. Hidden until a discount applies.
	local origPriceLabel = Instance.new("TextLabel")
	origPriceLabel.Name = "OrigPrice"
	origPriceLabel.Size = UDim2.new(1, -12, 0, 15)
	origPriceLabel.Position = UDim2.new(0, 6, 1, -BUY_H - 22)
	origPriceLabel.BackgroundTransparency = 1
	origPriceLabel.RichText = true
	origPriceLabel.Text = ""
	origPriceLabel.TextColor3 = Color3.fromRGB(168, 162, 158)
	origPriceLabel.Font = FONT_SMALL
	origPriceLabel.TextSize = IsMobile and 12 or 13
	origPriceLabel.TextXAlignment = Enum.TextXAlignment.Center
	origPriceLabel.Visible = false
	origPriceLabel.ZIndex = 6
	origPriceLabel.Parent = card

	-- Buy button
	local buyBtn = makeMCButton({
		name = "BuyBtn", size = UDim2.new(1, -12, 0, BUY_H),
		position = UDim2.new(0, 6, 1, -BUY_H - 5),
		color = C.buyBtn, hoverColor = C.buyBtnHover, pressColor = C.buyBtnPress,
		bevelHL = C.buyBtnBevelHL, bevelSH = C.buyBtnBevelSH,
		text = ROBUX_ICON .. " " .. tostring(pack.robux),
		textSize = IsMobile and 13 or 16,
		zIndex = 5, parent = card,
	})

	-- Register for the async, API-driven pricing render at the bottom of the
	-- script. Initial text is the plain configured value; refreshAllPricing
	-- replaces it with Roblox's accurate (Plus-aware) numbers once fetched.
	local entry = { btn = buyBtn, orig = origPriceLabel, productId = pack.productId, robux = pack.robux }
	table.insert(coinPackCards, entry)

	buyBtn.MouseButton1Click:Connect(function()
		if pack.productId and pack.productId ~= 0 then
			pcall(function() MarketplaceService:PromptProductPurchase(LocalPlayer, pack.productId) end)
		else
			-- Pack isn't wired to a real dev product yet — flash "Soon!" then
			-- restore the plain price.
			buyBtn.RichText = false
			origPriceLabel.Visible = false
			buyBtn.Text = "Soon!"
			task.delay(1.5, function()
				renderCardPricing(entry, nil, nil)
			end)
		end
	end)
end

-- Adjust coin section height for mobile 2x2
if IsMobile then
	coinSection.Size = UDim2.new(1, 0, 0, 360)
end

-- ============================================
-- SECTION: MODS (coming soon)
-- ============================================
local modsSection = Instance.new("Frame")
modsSection.Name = "ModsSection"
modsSection.Size = UDim2.new(1, 0, 0, IsMobile and 160 or 200)
modsSection.BackgroundColor3 = C.sectionBg; modsSection.BorderSizePixel = 0
modsSection.ZIndex = 3; modsSection.LayoutOrder = 2; modsSection.Parent = Scroll
addBevel(modsSection, C.sectionBevelHL, C.sectionBevelSH)

local modsHeader = Instance.new("TextLabel")
modsHeader.Size = UDim2.new(1, 0, 0, 28)
modsHeader.Position = UDim2.new(0, 12, 0, 6)
modsHeader.BackgroundTransparency = 1; modsHeader.Text = "Mods"
modsHeader.TextColor3 = C.textWhite; modsHeader.Font = FONT
modsHeader.TextSize = IsMobile and 16 or 20
modsHeader.TextXAlignment = Enum.TextXAlignment.Left
modsHeader.ZIndex = 4; modsHeader.Parent = modsSection

-- Coming soon placeholder cards
for i = 1, (IsMobile and 2 or 4) do
	local card = Instance.new("Frame")
	card.Name = "ModSlot" .. i
	card.Size = UDim2.new(IsMobile and 0.5 or 0.25, -CARD_PAD * 1.25, 0, IsMobile and 100 or 140)
	if IsMobile then
		local r = math.floor((i - 1) / 2)
		local c = (i - 1) % 2
		card.Position = UDim2.new(c * 0.5, CARD_PAD + c * CARD_PAD * 0.5, 0, 40 + r * (104 + CARD_PAD))
	else
		card.Position = UDim2.new((i - 1) * 0.25, CARD_PAD + (i - 1) * CARD_PAD * 0.25, 0, 40)
	end
	card.BackgroundColor3 = Color3.fromRGB(30, 27, 27); card.BorderSizePixel = 0
	card.ZIndex = 4; card.Parent = modsSection
	addBevel(card, Color3.fromRGB(42, 38, 38), Color3.fromRGB(18, 16, 16))

	local csLabel = Instance.new("TextLabel")
	csLabel.Size = UDim2.new(1, 0, 1, 0); csLabel.BackgroundTransparency = 1
	csLabel.Text = "Coming Soon"; csLabel.TextColor3 = Color3.fromRGB(70, 65, 65)
	csLabel.Font = FONT; csLabel.TextSize = IsMobile and 12 or 14
	csLabel.ZIndex = 5; csLabel.Parent = card
end

-- ============================================
-- OPEN / CLOSE
-- ============================================
local function updateBalance()
	BalanceLabel.Text = formatNumber(CurrentBalance)
end

-- Blur effect for shop
local shopBlur = Instance.new("BlurEffect")
shopBlur.Name = "ShopBlur"
shopBlur.Size = 0
shopBlur.Enabled = false
shopBlur.Parent = Lighting

-- UIs to hide when shop is open (same ones the title screen hides)
local GAME_UIS_TO_HIDE = {
	"InventoryGui",
	"CrosshairGui",
	"MainMenuButtonGui",
	"CoinHUD",
	"HelpBookButtonGui",
	"TipToastsGui",
	"MobileControlsGui",
	"LikesLeaderboardGui",
}

local function hideGameUIs()
	for _, name in ipairs(GAME_UIS_TO_HIDE) do
		local ui = PlayerGui:FindFirstChild(name)
		if ui then ui.Enabled = false end
	end
end

local function showGameUIs()
	for _, name in ipairs(GAME_UIS_TO_HIDE) do
		local ui = PlayerGui:FindFirstChild(name)
		if ui then ui.Enabled = true end
	end
end

local function openShop()
	if ShopOpen then return end
	print("[ShopUI] Opening shop...")
	ShopOpen = true

	-- Always hide game UIs when shop is open
	hideGameUIs()

	task.spawn(function()
		local ok, data = pcall(function() return GetCoinData:InvokeServer() end)
		if ok and data and data.coins then CurrentBalance = data.coins; updateBalance() end
	end)
	updateBalance()

	-- Reset scroll
	Scroll.CanvasPosition = Vector2.new(0, 0)

	-- Blur in
	shopBlur.Size = 0; shopBlur.Enabled = true
	TweenService:Create(shopBlur, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = 20,
	}):Play()

	local fullSize = Panel.Size
	local sx, sy = fullSize.X.Scale, fullSize.Y.Scale

	ScreenGui.Enabled = true
	Panel.Size = UDim2.new(sx * 0.85, 0, sy * 0.85, 0)
	Overlay.BackgroundTransparency = 1
	TweenService:Create(Panel, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = fullSize,
	}):Play()
	TweenService:Create(Overlay, TweenInfo.new(0.2), { BackgroundTransparency = 0.4 }):Play()
end

local function closeShop()
	if not ShopOpen then return end
	print("[ShopUI] Closing shop...")
	ShopOpen = false
	local wasFromTitle = OpenedFromTitle
	OpenedFromTitle = false

	-- Blur out
	TweenService:Create(shopBlur, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = 0,
	}):Play()

	local fullSize = UDim2.new(IsMobile and 0.95 or 0.85, 0, IsMobile and 0.9 or 0.82, 0)
	local sx, sy = fullSize.X.Scale, fullSize.Y.Scale
	local tp = TweenService:Create(Panel, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = UDim2.new(sx * 0.92, 0, sy * 0.92, 0),
	})
	local to = TweenService:Create(Overlay, TweenInfo.new(0.15), { BackgroundTransparency = 1 })
	tp:Play(); to:Play(); tp.Completed:Wait()
	ScreenGui.Enabled = false
	Panel.Size = fullSize
	shopBlur.Enabled = false

	if wasFromTitle then
		if _G.TitleScreen and _G.TitleScreen.Show then
			_G.TitleScreen.Show()
		end
	else
		-- Restore game UIs
		showGameUIs()
	end
end

local function toggleShop()
	if ShopOpen then closeShop() else openShop() end
end

CloseBtn.MouseButton1Click:Connect(closeShop)

_G.ShopUI.OpenFromTitleScreen = function()
	OpenedFromTitle = true
	openShop()
end

Overlay.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		closeShop()
	end
end)

-- (Shop button removed from CoinHUD — shop accessible via main menu M key)

-- ============================================
-- KEYBOARD SHORTCUT
-- ============================================
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.P then toggleShop() end
end)

-- ============================================
-- BALANCE SYNC
-- ============================================
if CoinBalanceUpdate then
	CoinBalanceUpdate.OnClientEvent:Connect(function(newBalance)
		if type(newBalance) == "number" then
			CurrentBalance = newBalance
			if ShopOpen then updateBalance() end
		end
	end)
end

task.spawn(function()
	task.wait(2)
	local ok, data = pcall(function() return GetCoinData:InvokeServer() end)
	if ok and data and data.coins then CurrentBalance = data.coins; updateBalance() end
end)

-- ============================================
-- PLUS DISCOUNT PREVIEW SYNC (accurate, API-driven)
-- Fetch each pack's real price from Roblox (Plus-aware) and render it. Done
-- per-card in parallel since GetProductInfoAsync yields. Roblox returns the
-- local player's user-specific PriceInRobux, so the preview matches the
-- purchase prompt exactly.
-- ============================================
local function refreshAllPricing()
	for _, entry in ipairs(coinPackCards) do
		task.spawn(function()
			local base, final = fetchProductPricing(entry.productId)
			renderCardPricing(entry, base, final)
		end)
	end
end

refreshAllPricing()

-- Re-fetch if Plus status flips mid-session (e.g. they subscribe via the Plus
-- panel and come back). Note: GetProductInfoAsync is cached by Roblox, so a
-- brand-new subscribe may not reflect until the cache refreshes — best effort.
-- The common case (already subscribed when the shop opens) is exact.
task.spawn(function()
	for _ = 1, 30 do
		if _G.PlusController then break end
		task.wait(0.2)
	end
	if _G.PlusController and _G.PlusController.OnChanged then
		_G.PlusController.OnChanged(refreshAllPricing)
	end
end)

print("[ShopUI] Initialized — Open via main menu or P key")
