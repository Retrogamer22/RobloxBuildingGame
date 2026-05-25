--[[
	CoinHUD.client.luau
	Top-right Build Coins display, MC stone grey style
	Positioned inline with menu button, matching player list width (200px)
	Layout: [Coins ~160] [4] [Menu 36] = 200px
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local CoinBalanceUpdate = Remotes:WaitForChild("CoinBalanceUpdate", 10)
local CoinNotification = Remotes:WaitForChild("CoinNotification", 10)
local GetCoinData = Remotes:WaitForChild("GetCoinData", 10)

-- ============================================
-- CONFIG
-- ============================================
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local COIN_COLOR = Color3.fromRGB(255, 200, 50)

-- Dark style (matching player list exactly)
local MC_BG = Color3.fromRGB(30, 30, 30)
local MC_BEVEL_LIGHT = Color3.fromRGB(80, 80, 80)
local MC_BEVEL_DARK = Color3.fromRGB(0, 0, 0)
local BEVEL = 2
local FONT = Enum.Font.Arcade

-- Layout constants (matching MainMenuButton & player list)
local BTN_SIZE = IsMobile and 40 or 36
local GAP = 4
local RIGHT_MARGIN = IsMobile and 6 or 10
local BTN_Y = IsMobile and 34 or 4

-- Total width matches player list on desktop (200px), slightly wider on mobile for touch
local TOTAL_W = IsMobile and 220 or 200
-- Strip layout: [Book BTN_SIZE] [GAP] [Coins COIN_W] [GAP] [Menu BTN_SIZE]
-- Coin display sits between the book button (left) and menu button (right)
local COIN_W = TOTAL_W - 2 * (BTN_SIZE + GAP)
local COIN_RIGHT = RIGHT_MARGIN + BTN_SIZE + GAP

-- ============================================
-- STATE
-- ============================================
local CurrentBalance = 0
local DisplayedBalance = 0
local IsAnimating = false

-- ============================================
-- BEVEL HELPER
-- ============================================
local function addBevel(parent, hlColor, shColor, zBase)
	local hl = hlColor or MC_BEVEL_LIGHT
	local sh = shColor or MC_BEVEL_DARK
	local z = (zBase or parent.ZIndex) + 1
	local top = Instance.new("Frame")
	top.Name = "BT"; top.Size = UDim2.new(1, 0, 0, BEVEL)
	top.BackgroundColor3 = hl; top.BorderSizePixel = 0; top.ZIndex = z; top.Parent = parent
	local left = Instance.new("Frame")
	left.Name = "BL"; left.Size = UDim2.new(0, BEVEL, 1, 0)
	left.BackgroundColor3 = hl; left.BorderSizePixel = 0; left.ZIndex = z; left.Parent = parent
	local bottom = Instance.new("Frame")
	bottom.Name = "BB"; bottom.Size = UDim2.new(1, 0, 0, BEVEL)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL)
	bottom.BackgroundColor3 = sh; bottom.BorderSizePixel = 0; bottom.ZIndex = z; bottom.Parent = parent
	local right = Instance.new("Frame")
	right.Name = "BR"; right.Size = UDim2.new(0, BEVEL, 1, 0)
	right.Position = UDim2.new(1, -BEVEL, 0, 0)
	right.BackgroundColor3 = sh; right.BorderSizePixel = 0; right.ZIndex = z; right.Parent = parent
	return {top = top, left = left, bottom = bottom, right = right}
end

-- ============================================
-- GUI CREATION
-- ============================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "CoinHUD"
ScreenGui.ResetOnSpawn = false
ScreenGui.DisplayOrder = 5
ScreenGui.ScreenInsets = Enum.ScreenInsets.None
ScreenGui.Parent = PlayerGui

-- Coin display container (MC grey, right-aligned)
local Container = Instance.new("Frame")
Container.Name = "CoinContainer"
Container.BackgroundColor3 = MC_BG
Container.BackgroundTransparency = 0.2
Container.BorderSizePixel = 0
Container.Size = UDim2.new(0, COIN_W, 0, BTN_SIZE)
Container.Position = UDim2.new(1, -COIN_RIGHT, 0, BTN_Y)
Container.AnchorPoint = Vector2.new(1, 0)
Container.ZIndex = 1
Container.Parent = ScreenGui

local coinBevels = addBevel(Container)
for _, bv in pairs(coinBevels) do bv.BackgroundTransparency = 0.3 end

-- Coin icon (gold circle with B, no stroke)
local iconSize = IsMobile and 22 or 24

local IconFrame = Instance.new("Frame")
IconFrame.Name = "CoinIcon"
IconFrame.BackgroundColor3 = COIN_COLOR
IconFrame.BorderSizePixel = 0
IconFrame.Size = UDim2.new(0, iconSize, 0, iconSize)
IconFrame.Position = UDim2.new(0, 6, 0.5, 0)
IconFrame.AnchorPoint = Vector2.new(0, 0.5)
IconFrame.ZIndex = 2
IconFrame.Parent = Container
Instance.new("UICorner", IconFrame).CornerRadius = UDim.new(1, 0)

local IconLabel = Instance.new("TextLabel")
IconLabel.Name = "CoinLetter"
IconLabel.Size = UDim2.new(1, 0, 1, 0)
IconLabel.BackgroundTransparency = 1
IconLabel.Text = "B"
IconLabel.TextColor3 = Color3.fromRGB(180, 130, 20)
IconLabel.TextStrokeColor3 = Color3.fromRGB(100, 70, 0)
IconLabel.TextStrokeTransparency = 0.3
IconLabel.Font = Enum.Font.GothamBold
IconLabel.TextScaled = true
IconLabel.ZIndex = 3
IconLabel.Parent = IconFrame

-- Balance text
local textX = 6 + iconSize + 4

local BalanceShadow = Instance.new("TextLabel")
BalanceShadow.Name = "BalanceShadow"
BalanceShadow.BackgroundTransparency = 1
BalanceShadow.Size = UDim2.new(1, -textX - 4, 1, 0)
BalanceShadow.Position = UDim2.new(0, textX + 1, 0, 2)
BalanceShadow.Text = "0"
BalanceShadow.TextColor3 = Color3.fromRGB(0, 0, 0)
BalanceShadow.Font = FONT
BalanceShadow.TextSize = IsMobile and 16 or 18
BalanceShadow.TextXAlignment = Enum.TextXAlignment.Left
BalanceShadow.ZIndex = 2
BalanceShadow.Parent = Container

local BalanceLabel = Instance.new("TextLabel")
BalanceLabel.Name = "BalanceLabel"
BalanceLabel.BackgroundTransparency = 1
BalanceLabel.Size = UDim2.new(1, -textX - 4, 1, 0)
BalanceLabel.Position = UDim2.new(0, textX, 0, 0)
BalanceLabel.Text = "0"
BalanceLabel.TextColor3 = COIN_COLOR
BalanceLabel.Font = FONT
BalanceLabel.TextSize = IsMobile and 16 or 18
BalanceLabel.TextXAlignment = Enum.TextXAlignment.Left
BalanceLabel.ZIndex = 3
BalanceLabel.Parent = Container

-- Popup container (below the display)
local PopupContainer = Instance.new("Frame")
PopupContainer.Name = "PopupContainer"
PopupContainer.BackgroundTransparency = 1
PopupContainer.Size = UDim2.new(0, 200, 0, 200)
PopupContainer.Position = UDim2.new(1, -RIGHT_MARGIN, 0, BTN_Y + BTN_SIZE)
PopupContainer.AnchorPoint = Vector2.new(1, 0)
PopupContainer.ZIndex = 10
PopupContainer.Parent = ScreenGui

-- ============================================
-- NUMBER FORMATTING
-- ============================================
local function formatNumber(n)
	if n >= 1000000 then return string.format("%.1fM", n / 1000000)
	elseif n >= 10000 then return string.format("%.1fK", n / 1000)
	elseif n >= 1000 then
		local s = tostring(math.floor(n))
		return s:sub(1, #s - 3) .. "," .. s:sub(#s - 2)
	else return tostring(math.floor(n)) end
end

-- ============================================
-- BALANCE ANIMATION
-- ============================================
local function animateBalance(targetBalance)
	CurrentBalance = targetBalance
	if IsAnimating then return end
	IsAnimating = true
	task.spawn(function()
		while math.abs(DisplayedBalance - CurrentBalance) > 0.5 do
			local diff = CurrentBalance - DisplayedBalance
			local step = math.sign(diff) * math.max(1, math.abs(diff) * 0.15)
			DisplayedBalance = DisplayedBalance + step
			if math.abs(DisplayedBalance - CurrentBalance) < 1 then
				DisplayedBalance = CurrentBalance
			end
			local text = formatNumber(DisplayedBalance)
			BalanceLabel.Text = text; BalanceShadow.Text = text
			task.wait()
		end
		DisplayedBalance = CurrentBalance
		local text = formatNumber(DisplayedBalance)
		BalanceLabel.Text = text; BalanceShadow.Text = text
		IsAnimating = false
	end)
end

-- ============================================
-- POPUP NOTIFICATION
-- ============================================
local popupQueue = {}
local isShowingPopup = false

local function showPopup(amount, reason)
	table.insert(popupQueue, { amount = amount, reason = reason })
	if isShowingPopup then return end
	isShowingPopup = true
	task.spawn(function()
		while #popupQueue > 0 do
			local popup = table.remove(popupQueue, 1)
			local shadow = Instance.new("TextLabel")
			shadow.BackgroundTransparency = 1; shadow.Size = UDim2.new(1, 0, 0, 24)
			shadow.Position = UDim2.new(0, 2, 0, 0)
			shadow.Text = "+" .. formatNumber(popup.amount)
			shadow.TextColor3 = Color3.fromRGB(50, 40, 0); shadow.Font = FONT
			shadow.TextSize = 18; shadow.TextXAlignment = Enum.TextXAlignment.Right
			shadow.ZIndex = 10; shadow.Parent = PopupContainer

			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1; label.Size = UDim2.new(1, 0, 0, 24)
			label.Position = UDim2.new(0, 0, 0, -2)
			label.Text = "+" .. formatNumber(popup.amount)
			label.TextColor3 = Color3.fromRGB(100, 255, 100); label.Font = FONT
			label.TextSize = 18; label.TextXAlignment = Enum.TextXAlignment.Right
			label.ZIndex = 11; label.Parent = PopupContainer

			task.spawn(function()
				local sz = UDim2.new(0, iconSize + 6, 0, iconSize + 6)
				local orig = UDim2.new(0, iconSize, 0, iconSize)
				TweenService:Create(IconFrame, TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Size = sz}):Play()
				task.wait(0.1)
				TweenService:Create(IconFrame, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = orig}):Play()
			end)

			TweenService:Create(label, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.new(0, 0, 0, 40), TextTransparency = 1,
			}):Play()
			TweenService:Create(shadow, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Position = UDim2.new(0, 2, 0, 42), TextTransparency = 1,
			}):Play()
			task.delay(1.3, function() label:Destroy(); shadow:Destroy() end)
			task.wait(0.3)
		end
		isShowingPopup = false
	end)
end

-- ============================================
-- REMOTES
-- ============================================
if CoinBalanceUpdate then
	CoinBalanceUpdate.OnClientEvent:Connect(function(newBalance)
		if type(newBalance) == "number" then animateBalance(newBalance) end
	end)
end
if CoinNotification then
	CoinNotification.OnClientEvent:Connect(function(amount, reason)
		if type(amount) == "number" and amount > 0 then showPopup(amount, reason) end
	end)
end

-- ============================================
-- INITIAL LOAD
-- ============================================
task.spawn(function()
	task.wait(2)
	if GetCoinData then
		local ok, data = pcall(function() return GetCoinData:InvokeServer() end)
		if ok and data and data.coins then
			CurrentBalance = data.coins; DisplayedBalance = data.coins
			local text = formatNumber(data.coins)
			BalanceLabel.Text = text; BalanceShadow.Text = text
		end
	end
end)

-- ============================================
-- ENTRANCE ANIMATION
-- ============================================
task.spawn(function()
	Container.Position = UDim2.new(1, -COIN_RIGHT + 160, 0, BTN_Y)
	Container.BackgroundTransparency = 1
	BalanceLabel.TextTransparency = 1; BalanceShadow.TextTransparency = 1
	IconFrame.BackgroundTransparency = 1; IconLabel.TextTransparency = 1

	task.wait(3)

	TweenService:Create(Container, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(1, -COIN_RIGHT, 0, BTN_Y),
	}):Play()
	TweenService:Create(Container, TweenInfo.new(0.3), { BackgroundTransparency = 0.2 }):Play()
	task.wait(0.15)
	TweenService:Create(BalanceLabel, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
	TweenService:Create(BalanceShadow, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
	TweenService:Create(IconFrame, TweenInfo.new(0.2), { BackgroundTransparency = 0 }):Play()
	TweenService:Create(IconLabel, TweenInfo.new(0.2), { TextTransparency = 0 }):Play()
end)

-- (Title screen visibility now handled by TitleScreen's uisToHide/uisToEnable)

print("[CoinHUD] Initialized (top-right, ~160px wide, MC grey)")
