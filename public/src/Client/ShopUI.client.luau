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
local ModConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ModConfig"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local GetCoinData = Remotes:WaitForChild("GetCoinData", 10)
local CoinBalanceUpdate = Remotes:WaitForChild("CoinBalanceUpdate", 10)
local ShopOpened = Remotes:WaitForChild("ShopOpened", 10)
local BuyMod = Remotes:WaitForChild("BuyMod", 10)
local GetOwnedMods = Remotes:WaitForChild("GetOwnedMods", 10)

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
local OwnedMods = {} -- modId -> true (synced from server on open / after purchase)
local refreshAllModCards -- forward decl; assigned after updateBalance is defined
local openModInfo -- forward decl; assigned by the "More Info" modal below

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

-- Registry of mod cards { mod, card, btn, btnBevels, priceFrame, priceLabel, buyable }.
-- Filled as the Mods section is built; iterated by refreshAllModCards.
local modCards = {}

-- Mods are bought with coins, so the Plus discount is the in-game coin discount
-- (mirrors PlusController.GetDiscountedPrice, used everywhere coins are spent).
-- Falls back to the base price if the Plus controller isn't ready yet.
local function modCoinPrice(base)
	base = tonumber(base) or 0
	if _G.PlusController and _G.PlusController.GetDiscountedPrice then
		local ok, p = pcall(_G.PlusController.GetDiscountedPrice, base)
		if ok and type(p) == "number" then return p end
	end
	return base
end

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

-- Mod cards (data-driven from ModConfig). Owned / Coming Soon / buyable state is
-- rendered later by refreshAllModCards once balance + ownership are known.
local MOD_COLS = IsMobile and 2 or 4
local MOD_CARD_H = IsMobile and 112 or 150
local MOD_TOP = 40
local MOD_GRAY_HL = Color3.fromRGB(80, 74, 74)
local MOD_GRAY_SH = Color3.fromRGB(30, 26, 26)
local MOD_OWNED_BG = Color3.fromRGB(70, 64, 64)
local MOD_SOON_BG = Color3.fromRGB(55, 50, 50)

local modList = ModConfig.GetAll()
-- Always fill at least one full row so the section never looks broken.
local MOD_SLOTS = math.max(#modList, MOD_COLS)
local modRows = math.ceil(MOD_SLOTS / MOD_COLS)
modsSection.Size = UDim2.new(1, 0, 0, MOD_TOP + modRows * (MOD_CARD_H + CARD_PAD) + 4)

local function placeModCard(card, slotIndex)
	local col = (slotIndex - 1) % MOD_COLS
	local row = math.floor((slotIndex - 1) / MOD_COLS)
	card.Size = UDim2.new(1 / MOD_COLS, -CARD_PAD * 1.25, 0, MOD_CARD_H)
	card.Position = UDim2.new(col * (1 / MOD_COLS), CARD_PAD + col * CARD_PAD * 0.25, 0, MOD_TOP + row * (MOD_CARD_H + CARD_PAD))
end

for slot = 1, MOD_SLOTS do
	if slot <= #modList then
		local mod = modList[slot]

		local card = Instance.new("Frame")
		card.Name = "ModCard_" .. tostring(mod.id)
		card.BackgroundColor3 = C.cardBg; card.BorderSizePixel = 0
		card.ZIndex = 4; card.Parent = modsSection
		placeModCard(card, slot)
		addBevel(card, C.cardBevelHL, C.cardBevelSH)

		-- Icon
		local img = Instance.new("ImageLabel")
		img.Name = "ModImage"
		img.Size = UDim2.new(1, -10, 0, MOD_CARD_H - 80)
		img.Position = UDim2.new(0, 5, 0, 4)
		img.BackgroundColor3 = Color3.fromRGB(30, 27, 27); img.BackgroundTransparency = 0.4
		img.BorderSizePixel = 0
		img.Image = (type(mod.image) == "string" and mod.image ~= "" and mod.image ~= "rbxassetid://0") and mod.image or ""
		img.ScaleType = Enum.ScaleType.Fit; img.ZIndex = 5; img.Parent = card

		-- Name
		local nameL = Instance.new("TextLabel")
		nameL.Name = "ModName"
		nameL.Size = UDim2.new(1, -10, 0, 18)
		nameL.Position = UDim2.new(0, 5, 0, MOD_CARD_H - 74)
		nameL.BackgroundTransparency = 1; nameL.Text = mod.name or mod.id
		nameL.TextColor3 = C.textWhite; nameL.Font = FONT; nameL.TextSize = IsMobile and 11 or 13
		nameL.TextXAlignment = Enum.TextXAlignment.Center; nameL.TextTruncate = Enum.TextTruncate.AtEnd
		nameL.ZIndex = 5; nameL.Parent = card

		-- Price row (gold coin + amount), centered. Hidden when owned / coming soon.
		local priceFrame = Instance.new("Frame")
		priceFrame.Name = "PriceRow"
		priceFrame.Size = UDim2.new(1, -10, 0, 16)
		priceFrame.Position = UDim2.new(0, 5, 0, MOD_CARD_H - 54)
		priceFrame.BackgroundTransparency = 1; priceFrame.ZIndex = 5; priceFrame.Parent = card
		local pl = Instance.new("UIListLayout")
		pl.FillDirection = Enum.FillDirection.Horizontal
		pl.HorizontalAlignment = Enum.HorizontalAlignment.Center
		pl.VerticalAlignment = Enum.VerticalAlignment.Center
		pl.SortOrder = Enum.SortOrder.LayoutOrder; pl.Padding = UDim.new(0, 3); pl.Parent = priceFrame

		local coin = Instance.new("Frame")
		coin.Size = UDim2.new(0, 12, 0, 12); coin.BackgroundColor3 = C.gold; coin.BorderSizePixel = 0
		coin.LayoutOrder = 1; coin.ZIndex = 6; coin.Parent = priceFrame
		Instance.new("UICorner", coin).CornerRadius = UDim.new(1, 0)
		local coinTxt = Instance.new("TextLabel")
		coinTxt.Size = UDim2.new(1, 0, 1, 0); coinTxt.BackgroundTransparency = 1; coinTxt.Text = "B"
		coinTxt.TextColor3 = Color3.fromRGB(180, 130, 20); coinTxt.Font = Enum.Font.GothamBold
		coinTxt.TextScaled = true; coinTxt.ZIndex = 7; coinTxt.Parent = coin

		local priceL = Instance.new("TextLabel")
		priceL.Name = "PriceText"; priceL.AutomaticSize = Enum.AutomaticSize.X
		priceL.Size = UDim2.new(0, 0, 1, 0); priceL.BackgroundTransparency = 1; priceL.RichText = true
		priceL.Text = ""; priceL.TextColor3 = C.gold; priceL.Font = FONT; priceL.TextSize = IsMobile and 12 or 14
		priceL.LayoutOrder = 2; priceL.ZIndex = 6; priceL.Parent = priceFrame

		-- Buy button (custom so owned / coming-soon states fully control appearance)
		local btn = Instance.new("TextButton")
		btn.Name = "BuyBtn"; btn.Size = UDim2.new(1, -12, 0, BUY_H)
		btn.Position = UDim2.new(0, 6, 1, -BUY_H - 5)
		btn.BackgroundColor3 = C.buyBtn; btn.BorderSizePixel = 0
		btn.Text = "Buy"; btn.TextColor3 = C.textWhite; btn.Font = FONT
		btn.TextSize = IsMobile and 12 or 14; btn.AutoButtonColor = false; btn.ZIndex = 5; btn.Parent = card
		local btnBevels = addBevel(btn, C.buyBtnBevelHL, C.buyBtnBevelSH)

		local entry = {
			mod = mod, card = card, btn = btn, btnBevels = btnBevels,
			priceFrame = priceFrame, priceLabel = priceL, buyable = false,
		}

		btn.MouseEnter:Connect(function()
			if entry.buyable then btn.BackgroundColor3 = C.buyBtnHover end
		end)
		btn.MouseLeave:Connect(function()
			if entry.buyable then btn.BackgroundColor3 = C.buyBtn; setBevel(btnBevels, C.buyBtnBevelHL, C.buyBtnBevelSH) end
		end)
		btn.MouseButton1Down:Connect(function()
			if entry.buyable then btn.BackgroundColor3 = C.buyBtnPress; setBevel(btnBevels, C.buyBtnBevelSH, C.buyBtnBevelHL) end
		end)
		btn.MouseButton1Up:Connect(function()
			if entry.buyable then btn.BackgroundColor3 = C.buyBtnHover; setBevel(btnBevels, C.buyBtnBevelHL, C.buyBtnBevelSH) end
		end)

		-- Click the card (anywhere except the Buy button) opens "More Info".
		local infoHit = Instance.new("TextButton")
		infoHit.Name = "InfoHit"
		infoHit.BackgroundTransparency = 1; infoHit.Text = ""
		infoHit.AutoButtonColor = false; infoHit.BorderSizePixel = 0
		infoHit.Size = UDim2.new(1, 0, 1, -(BUY_H + 8))
		infoHit.Position = UDim2.new(0, 0, 0, 0)
		infoHit.ZIndex = 8; infoHit.Parent = card
		infoHit.MouseButton1Click:Connect(function()
			if openModInfo then openModInfo(mod) end
		end)
		entry.infoHit = infoHit

		table.insert(modCards, entry)
	else
		-- Filler "More Soon" slot to keep the row looking complete
		local card = Instance.new("Frame")
		card.Name = "ModSlotEmpty" .. tostring(slot)
		card.BackgroundColor3 = Color3.fromRGB(30, 27, 27); card.BorderSizePixel = 0
		card.ZIndex = 4; card.Parent = modsSection
		placeModCard(card, slot)
		addBevel(card, Color3.fromRGB(42, 38, 38), Color3.fromRGB(18, 16, 16))

		local csLabel = Instance.new("TextLabel")
		csLabel.Size = UDim2.new(1, 0, 1, 0); csLabel.BackgroundTransparency = 1
		csLabel.Text = "More Soon"; csLabel.TextColor3 = Color3.fromRGB(70, 65, 65)
		csLabel.Font = FONT; csLabel.TextSize = IsMobile and 12 or 14
		csLabel.ZIndex = 5; csLabel.Parent = card
	end
end

-- ============================================
-- MOD "MORE INFO" MODAL
-- Opened by clicking a mod card (handled in the card loop above).
-- Content is data-driven from mod.info (see ModConfig).
-- ============================================
local INFO_HEAD_H = IsMobile and 40 or 50

-- Scrim: dims the shop behind the modal and closes it when clicked.
local InfoScrim = Instance.new("TextButton")
InfoScrim.Name = "ModInfoScrim"
InfoScrim.Size = UDim2.new(1, 0, 1, 0)
InfoScrim.BackgroundColor3 = C.overlay; InfoScrim.BackgroundTransparency = 0.4
InfoScrim.BorderSizePixel = 0; InfoScrim.AutoButtonColor = false; InfoScrim.Text = ""
InfoScrim.ZIndex = 40; InfoScrim.Visible = false; InfoScrim.Active = true
InfoScrim.Parent = ScreenGui

local InfoPanel = Instance.new("Frame")
InfoPanel.Name = "ModInfoPanel"
InfoPanel.Size = UDim2.new(IsMobile and 0.92 or 0.6, 0, IsMobile and 0.88 or 0.78, 0)
InfoPanel.Position = UDim2.new(0.5, 0, 0.5, 0); InfoPanel.AnchorPoint = Vector2.new(0.5, 0.5)
InfoPanel.BackgroundColor3 = C.panelBg; InfoPanel.BorderSizePixel = 0
InfoPanel.ZIndex = 41; InfoPanel.Active = true; InfoPanel.Parent = InfoScrim
addBevel(InfoPanel)

local InfoHeader = Instance.new("Frame")
InfoHeader.Name = "Header"; InfoHeader.Size = UDim2.new(1, 0, 0, INFO_HEAD_H)
InfoHeader.BackgroundColor3 = C.headerBg; InfoHeader.BorderSizePixel = 0
InfoHeader.ZIndex = 42; InfoHeader.Parent = InfoPanel
addBevel(InfoHeader, C.bevelHL, C.bevelSH)

local InfoTitle = Instance.new("TextLabel")
InfoTitle.Name = "Title"; InfoTitle.Size = UDim2.new(1, -60, 1, 0); InfoTitle.Position = UDim2.new(0, 14, 0, 0)
InfoTitle.BackgroundTransparency = 1; InfoTitle.Text = "MOD INFO"
InfoTitle.TextColor3 = C.textWhite; InfoTitle.Font = FONT; InfoTitle.TextSize = IsMobile and 18 or 24
InfoTitle.TextXAlignment = Enum.TextXAlignment.Left; InfoTitle.TextTruncate = Enum.TextTruncate.AtEnd
InfoTitle.ZIndex = 43; InfoTitle.Parent = InfoHeader

local InfoScroll = Instance.new("ScrollingFrame")
InfoScroll.Name = "Body"
InfoScroll.Size = UDim2.new(1, -16, 1, -INFO_HEAD_H - 12)
InfoScroll.Position = UDim2.new(0, 8, 0, INFO_HEAD_H + 4)
InfoScroll.BackgroundTransparency = 1; InfoScroll.BorderSizePixel = 0
InfoScroll.ScrollBarThickness = IsMobile and 4 or 6
InfoScroll.ScrollBarImageColor3 = Color3.fromRGB(80, 70, 70)
InfoScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
InfoScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
InfoScroll.ScrollingDirection = Enum.ScrollingDirection.Y
InfoScroll.ZIndex = 42; InfoScroll.Parent = InfoPanel

local InfoListLayout = Instance.new("UIListLayout")
InfoListLayout.SortOrder = Enum.SortOrder.LayoutOrder; InfoListLayout.Padding = UDim.new(0, 10)
InfoListLayout.Parent = InfoScroll
local InfoBodyPad = Instance.new("UIPadding")
InfoBodyPad.PaddingLeft = UDim.new(0, 6); InfoBodyPad.PaddingRight = UDim.new(0, 10)
InfoBodyPad.PaddingTop = UDim.new(0, 6); InfoBodyPad.PaddingBottom = UDim.new(0, 8)
InfoBodyPad.Parent = InfoScroll

-- Resolve an image KEY (from mod.info.features[i].image) to an asset id, or ""
-- when it's still the rbxassetid://0 placeholder (so we draw a "?" box instead).
local function resolveInfoImage(info, key)
	if type(info) ~= "table" or type(info.images) ~= "table" then return "" end
	local v = info.images[key]
	if type(v) == "string" and v ~= "" and v ~= "rbxassetid://0" then return v end
	return ""
end

-- A bevelled image box; shows a "?" placeholder until the asset id is filled in.
local function makeInfoImage(parent, assetId, box)
	local holder = Instance.new("Frame")
	holder.Size = UDim2.new(0, box, 0, box); holder.BackgroundColor3 = Color3.fromRGB(30, 27, 27)
	holder.BorderSizePixel = 0; holder.ZIndex = 43; holder.Parent = parent
	addInsetBevel(holder, nil, nil, 1)
	local img = Instance.new("ImageLabel")
	img.Size = UDim2.new(1, -6, 1, -6); img.Position = UDim2.new(0, 3, 0, 3)
	img.BackgroundTransparency = 1; img.ScaleType = Enum.ScaleType.Fit
	img.Image = assetId; img.ZIndex = 44; img.Parent = holder
	if assetId == "" then
		local q = Instance.new("TextLabel")
		q.Size = UDim2.new(1, 0, 1, 0); q.BackgroundTransparency = 1; q.Text = "?"
		q.TextColor3 = Color3.fromRGB(70, 65, 65); q.Font = FONT; q.TextSize = math.floor(box * 0.5)
		q.ZIndex = 45; q.Parent = holder
	end
	return holder
end

-- Content frames are rebuilt on every open so the modal matches the clicked mod.
local infoContentFrames = {}
local function clearInfoContent()
	for _, f in ipairs(infoContentFrames) do f:Destroy() end
	infoContentFrames = {}
end

local closeModInfo
openModInfo = function(mod)
	if type(mod) ~= "table" then return end
	local info = type(mod.info) == "table" and mod.info or {}
	InfoTitle.Text = string.upper(tostring(mod.name or mod.id or "Mod"))
	clearInfoContent()

	local order = 0
	local function nextOrder() order = order + 1; return order end

	-- HERO: big icon + tagline/overview.
	local hero = Instance.new("Frame")
	hero.Name = "Hero"; hero.Size = UDim2.new(1, 0, 0, 0)
	hero.AutomaticSize = Enum.AutomaticSize.Y; hero.BackgroundColor3 = C.sectionBg
	hero.BorderSizePixel = 0; hero.ZIndex = 42; hero.LayoutOrder = nextOrder(); hero.Parent = InfoScroll
	addBevel(hero, C.sectionBevelHL, C.sectionBevelSH)
	local heroPad = Instance.new("UIPadding")
	heroPad.PaddingLeft = UDim.new(0, 10); heroPad.PaddingRight = UDim.new(0, 10)
	heroPad.PaddingTop = UDim.new(0, 10); heroPad.PaddingBottom = UDim.new(0, 10); heroPad.Parent = hero

	local HERO_BOX = IsMobile and 64 or 88
	local heroImgId = (type(mod.image) == "string" and mod.image ~= "" and mod.image ~= "rbxassetid://0")
		and mod.image or resolveInfoImage(info, "PaintCanImage")
	local heroImg = makeInfoImage(hero, heroImgId, HERO_BOX)
	heroImg.Position = UDim2.new(0, 0, 0, 0)

	local heroText = Instance.new("TextLabel")
	heroText.Name = "HeroText"
	heroText.Position = UDim2.new(0, HERO_BOX + 12, 0, 0)
	heroText.Size = UDim2.new(1, -(HERO_BOX + 12), 0, 0)
	heroText.AutomaticSize = Enum.AutomaticSize.Y; heroText.BackgroundTransparency = 1
	heroText.RichText = true; heroText.TextWrapped = true
	heroText.TextXAlignment = Enum.TextXAlignment.Left; heroText.TextYAlignment = Enum.TextYAlignment.Top
	heroText.Font = FONT_SMALL; heroText.TextColor3 = C.textWhite; heroText.TextSize = IsMobile and 13 or 15
	heroText.ZIndex = 43; heroText.Parent = hero
	local tagline = info.tagline
	local overview = info.overview or mod.description or ""
	if tagline and tagline ~= "" then
		heroText.Text = string.format('<font color="rgb(255,200,50)"><b>%s</b></font>\n\n%s', tagline, overview)
	else
		heroText.Text = overview
	end
	table.insert(infoContentFrames, hero)

	-- STATUS strip: price + availability. Informational only — no Buy button here.
	local status = Instance.new("Frame")
	status.Name = "Status"; status.Size = UDim2.new(1, 0, 0, IsMobile and 26 or 30)
	status.BackgroundColor3 = C.sectionBg; status.BorderSizePixel = 0
	status.ZIndex = 42; status.LayoutOrder = nextOrder(); status.Parent = InfoScroll
	addBevel(status, C.sectionBevelHL, C.sectionBevelSH)
	local statusL = Instance.new("TextLabel")
	statusL.Size = UDim2.new(1, -20, 1, 0); statusL.Position = UDim2.new(0, 10, 0, 0)
	statusL.BackgroundTransparency = 1; statusL.RichText = true
	statusL.TextXAlignment = Enum.TextXAlignment.Left; statusL.Font = FONT
	statusL.TextColor3 = C.gold; statusL.TextSize = IsMobile and 13 or 15; statusL.ZIndex = 43; statusL.Parent = status
	if OwnedMods[mod.id] == true then
		statusL.Text = '<font color="rgb(170,170,170)">You own this mod.</font>'
	else
		local base = tonumber(mod.coinPrice) or 0
		local final = modCoinPrice(base)
		local priceStr
		if final < base then
			priceStr = string.format("<s>%s</s> %s", formatNumber(base), formatNumber(final))
		else
			priceStr = formatNumber(final)
		end
		local avail = (mod.available == true) and "Available now" or "Coming Soon"
		statusL.Text = string.format('%s Build Coins  <font color="rgb(120,110,110)">    %s</font>', priceStr, avail)
	end
	table.insert(infoContentFrames, status)

	-- FEATURE rows.
	local feats = type(info.features) == "table" and info.features or {}
	if #feats > 0 then
		local fh = Instance.new("TextLabel")
		fh.Name = "FeaturesHeader"; fh.Size = UDim2.new(1, 0, 0, IsMobile and 22 or 26)
		fh.BackgroundTransparency = 1; fh.Text = "What's inside"
		fh.TextColor3 = C.gold; fh.Font = FONT; fh.TextSize = IsMobile and 15 or 18
		fh.TextXAlignment = Enum.TextXAlignment.Left; fh.ZIndex = 42
		fh.LayoutOrder = nextOrder(); fh.Parent = InfoScroll
		table.insert(infoContentFrames, fh)

		for _, feat in ipairs(feats) do
			local row = Instance.new("Frame")
			row.Name = "Feature"; row.Size = UDim2.new(1, 0, 0, 0)
			row.AutomaticSize = Enum.AutomaticSize.Y; row.BackgroundColor3 = C.cardBg
			row.BorderSizePixel = 0; row.ZIndex = 42; row.LayoutOrder = nextOrder(); row.Parent = InfoScroll
			addBevel(row, C.cardBevelHL, C.cardBevelSH)
			local rp = Instance.new("UIPadding")
			rp.PaddingLeft = UDim.new(0, 10); rp.PaddingRight = UDim.new(0, 10)
			rp.PaddingTop = UDim.new(0, 8); rp.PaddingBottom = UDim.new(0, 8); rp.Parent = row

			local BOX = IsMobile and 48 or 60
			local fimg = makeInfoImage(row, resolveInfoImage(info, feat.image), BOX)
			fimg.Position = UDim2.new(0, 0, 0, 0)

			local txt = Instance.new("TextLabel")
			txt.Position = UDim2.new(0, BOX + 12, 0, 0)
			txt.Size = UDim2.new(1, -(BOX + 12), 0, 0); txt.AutomaticSize = Enum.AutomaticSize.Y
			txt.BackgroundTransparency = 1; txt.RichText = true; txt.TextWrapped = true
			txt.TextXAlignment = Enum.TextXAlignment.Left; txt.TextYAlignment = Enum.TextYAlignment.Top
			txt.Font = FONT_SMALL; txt.TextColor3 = C.textWhite; txt.TextSize = IsMobile and 12 or 14
			txt.ZIndex = 43; txt.Parent = row
			txt.Text = string.format('<font color="rgb(255,255,255)"><b>%s</b></font>\n<font color="rgb(190,185,185)">%s</font>', tostring(feat.name or ""), tostring(feat.text or ""))
			table.insert(infoContentFrames, row)
		end
	end

	InfoScroll.CanvasPosition = Vector2.new(0, 0)
	InfoScrim.Visible = true
end

closeModInfo = function()
	InfoScrim.Visible = false
	clearInfoContent()
end

-- Close: X button + clicking the dimmed scrim. The panel is Active so clicks
-- inside it don't fall through to the scrim.
local InfoCloseBtn = makeMCButton({
	name = "InfoClose", size = UDim2.new(0, IsMobile and 32 or 36, 0, IsMobile and 32 or 36),
	position = UDim2.new(1, -(IsMobile and 32 or 36) - 6, 0.5, 0), anchorPoint = Vector2.new(0, 0.5),
	color = C.closeBtn, hoverColor = C.closeBtnHover, pressColor = C.closeBtnPress,
	bevelHL = C.closeBtnBevelHL, bevelSH = C.closeBtnBevelSH,
	text = "X", textSize = IsMobile and 16 or 18, zIndex = 43, parent = InfoHeader,
})
InfoCloseBtn.MouseButton1Click:Connect(function() closeModInfo() end)
InfoScrim.MouseButton1Click:Connect(function() closeModInfo() end)

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
	-- Funnel: tell the server the shop was opened (throttled + logged server-side).
	if ShopOpened then pcall(function() ShopOpened:FireServer() end) end

	-- Always hide game UIs when shop is open
	hideGameUIs()

	task.spawn(function()
		local ok, data = pcall(function() return GetCoinData:InvokeServer() end)
		if ok and data then
			if data.coins then CurrentBalance = data.coins; updateBalance() end
			if type(data.ownedMods) == "table" then OwnedMods = data.ownedMods end
			if refreshAllModCards then refreshAllModCards() end
		end
	end)
	updateBalance()
	if refreshAllModCards then refreshAllModCards() end

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
			if refreshAllModCards then refreshAllModCards() end
		end
	end)
end

task.spawn(function()
	task.wait(2)
	local ok, data = pcall(function() return GetCoinData:InvokeServer() end)
	if ok and data then
		if data.coins then CurrentBalance = data.coins; updateBalance() end
		if type(data.ownedMods) == "table" then OwnedMods = data.ownedMods end
		if refreshAllModCards then refreshAllModCards() end
	end
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
		_G.PlusController.OnChanged(function()
			refreshAllPricing()
			if refreshAllModCards then refreshAllModCards() end
		end)
	end
end)

-- ============================================
-- MOD CARD RENDERING + PURCHASE
-- ============================================
local function renderModCard(entry)
	local mod, btn = entry.mod, entry.btn
	local owned = OwnedMods[mod.id] == true
	if owned then
		entry.buyable = false
		entry.priceFrame.Visible = false
		btn.Text = "Owned"; btn.TextColor3 = C.textDim
		btn.BackgroundColor3 = MOD_OWNED_BG; setBevel(entry.btnBevels, MOD_GRAY_HL, MOD_GRAY_SH)
	elseif mod.available ~= true then
		entry.buyable = false
		entry.priceFrame.Visible = false
		btn.Text = "Coming Soon"; btn.TextColor3 = C.textMuted
		btn.BackgroundColor3 = MOD_SOON_BG; setBevel(entry.btnBevels, MOD_GRAY_HL, MOD_GRAY_SH)
	else
		entry.priceFrame.Visible = true
		local base = tonumber(mod.coinPrice) or 0
		local final = modCoinPrice(base)
		if final < base then
			entry.priceLabel.Text = string.format("<s>%s</s>  %s", formatNumber(base), formatNumber(final))
		else
			entry.priceLabel.Text = formatNumber(final)
		end
		btn.Text = "Buy"; btn.TextColor3 = C.textWhite
		if CurrentBalance < final then
			-- Can't afford yet: dim + no hover, but a click still flashes a hint.
			entry.buyable = false
			btn.BackgroundColor3 = C.buyBtnPress; setBevel(entry.btnBevels, C.buyBtnBevelHL, C.buyBtnBevelSH)
		else
			entry.buyable = true
			btn.BackgroundColor3 = C.buyBtn; setBevel(entry.btnBevels, C.buyBtnBevelHL, C.buyBtnBevelSH)
		end
	end
end

refreshAllModCards = function()
	for _, entry in ipairs(modCards) do
		renderModCard(entry)
	end
end

local function attemptBuyMod(entry)
	local mod = entry.mod
	if OwnedMods[mod.id] or mod.available ~= true then return end
	local base = tonumber(mod.coinPrice) or 0
	local final = modCoinPrice(base)
	if CurrentBalance < final then
		entry.btn.Text = "Need Coins"
		task.delay(1.2, function() renderModCard(entry) end)
		return
	end
	-- Lock the button while the request is in flight
	entry.buyable = false
	entry.btn.Text = "..."
	task.spawn(function()
		local ok, res = pcall(function() return BuyMod:InvokeServer(mod.id) end)
		if ok and type(res) == "table" then
			if type(res.balance) == "number" then CurrentBalance = res.balance; updateBalance() end
			if type(res.owned) == "table" then OwnedMods = res.owned end
			if (not res.ok) and type(res.message) == "string" then
				entry.btn.Text = res.message
				task.wait(1.2)
			end
		else
			entry.btn.Text = "Error"
			task.wait(1.2)
		end
		refreshAllModCards()
	end)
end

for _, entry in ipairs(modCards) do
	entry.btn.MouseButton1Click:Connect(function() attemptBuyMod(entry) end)
end

refreshAllModCards()

print("[ShopUI] Initialized — Open via main menu or P key")
