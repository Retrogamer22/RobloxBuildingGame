--[[
	SaveLoadUI (Client)
	Multi-slot save/load interface with slot selection, purchase, management
	Minecraft stone-style UI matching TitleScreen aesthetic
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local OpenSaveLoadUI = Remotes:WaitForChild("OpenSaveLoadUI", 10)
local SavePlot = Remotes:WaitForChild("SavePlot", 10)
local LoadPlot = Remotes:WaitForChild("LoadPlot", 10)
local LoadAutosave = Remotes:WaitForChild("LoadAutosave", 10)
local SaveLoadResult = Remotes:WaitForChild("SaveLoadResult", 10)
local GetSlotInfo = Remotes:WaitForChild("GetSlotInfo", 10)
local DeleteSlot = Remotes:WaitForChild("DeleteSlot", 10)
local PurchaseSlot = Remotes:WaitForChild("PurchaseSlot", 10)
local PurchaseSlotWithCoins = Remotes:WaitForChild("PurchaseSlotWithCoins", 10)
local RenameSlot = Remotes:WaitForChild("RenameSlot", 10)

-- ============================================
-- MINECRAFT-STYLE COLORS
-- ============================================
local COLORS = {
	-- Panel
	panelBg = Color3.fromRGB(60, 60, 60),
	panelHighlight = Color3.fromRGB(100, 100, 100),
	panelShadow = Color3.fromRGB(30, 30, 30),
	
	-- Slots
	slotEmpty = Color3.fromRGB(80, 80, 80),
	slotFilled = Color3.fromRGB(100, 100, 100),
	slotSelected = Color3.fromRGB(60, 80, 110),
	slotHover = Color3.fromRGB(110, 110, 110),
	slotHighlight = Color3.fromRGB(140, 140, 140),
	slotShadow = Color3.fromRGB(45, 45, 45),
	slotSelectedHighlight = Color3.fromRGB(100, 150, 200),
	slotSelectedShadow = Color3.fromRGB(40, 70, 100),
	
	-- Slot number badge
	badgeEmpty = Color3.fromRGB(50, 50, 55),
	badgeFilled = Color3.fromRGB(55, 75, 95),
	
	-- Inner container
	innerBg = Color3.fromRGB(20, 20, 20),
	innerHighlight = Color3.fromRGB(50, 50, 50),
	innerShadow = Color3.fromRGB(10, 10, 10),
	
	-- Buttons (Minecraft-style)
	buttonNormal = Color3.fromRGB(110, 110, 110),
	buttonHover = Color3.fromRGB(130, 130, 130),
	buttonHighlight = Color3.fromRGB(160, 160, 160),
	buttonShadow = Color3.fromRGB(55, 55, 55),
	buttonDisabled = Color3.fromRGB(70, 70, 70),
	buttonDisabledHighlight = Color3.fromRGB(95, 95, 95),
	buttonDisabledShadow = Color3.fromRGB(35, 35, 35),
	
	-- Colored buttons
	saveNormal = Color3.fromRGB(60, 130, 60),
	saveHover = Color3.fromRGB(80, 150, 80),
	saveHighlight = Color3.fromRGB(100, 190, 100),
	saveShadow = Color3.fromRGB(30, 70, 30),
	
	loadNormal = Color3.fromRGB(50, 100, 150),
	loadHover = Color3.fromRGB(70, 120, 170),
	loadHighlight = Color3.fromRGB(90, 150, 200),
	loadShadow = Color3.fromRGB(25, 50, 80),
	
	-- Autosave restore button: amber/teal so it reads as "recovery", distinct from blue Load
	autosaveNormal = Color3.fromRGB(150, 110, 40),
	autosaveHover = Color3.fromRGB(175, 130, 55),
	autosaveHighlight = Color3.fromRGB(205, 160, 75),
	autosaveShadow = Color3.fromRGB(80, 58, 20),
	
	deleteNormal = Color3.fromRGB(140, 50, 50),
	deleteHover = Color3.fromRGB(160, 60, 60),
	deleteHighlight = Color3.fromRGB(190, 80, 80),
	deleteShadow = Color3.fromRGB(70, 25, 25),
	
	-- Coin purchase (yellow)
	purchaseNormal = Color3.fromRGB(150, 130, 40),
	purchaseHover = Color3.fromRGB(170, 150, 60),
	purchaseHighlight = Color3.fromRGB(200, 180, 80),
	purchaseShadow = Color3.fromRGB(80, 65, 20),
	-- Robux purchase (green)
	purchaseRobuxNormal = Color3.fromRGB(40, 140, 50),
	purchaseRobuxHover = Color3.fromRGB(55, 160, 65),
	purchaseRobuxHighlight = Color3.fromRGB(80, 190, 90),
	purchaseRobuxShadow = Color3.fromRGB(20, 70, 25),
	
	closeNormal = Color3.fromRGB(90, 90, 90),
	closeHover = Color3.fromRGB(110, 110, 110),
	closeHighlight = Color3.fromRGB(140, 140, 140),
	closeShadow = Color3.fromRGB(45, 45, 45),
	
	-- Text
	text = Color3.fromRGB(255, 255, 255),
	textDim = Color3.fromRGB(180, 180, 180),
	textShadow = Color3.fromRGB(20, 20, 20),
	textSuccess = Color3.fromRGB(100, 255, 100),
	textError = Color3.fromRGB(255, 100, 100),
	textWarning = Color3.fromRGB(255, 193, 7),
	textDisabled = Color3.fromRGB(100, 100, 100),
}

local BORDER_SIZE = 3
local FONT = Enum.Font.Arcade

-- Constants
local SLOT_PRICE_ROBUX = 100
local SLOT_PRICE_COINS = 1000
local ROBUX_ICON = utf8.char(0xE002)
local COIN_ICON = utf8.char(0xE009) -- Fallback if no coin icon; will use text

-- Track state
local isProcessing = false
local selectedSlot = nil
local slotData = nil
local slotFrames = {}

-- Blur effect for background
local saveLoadBlur = nil

-- Mouse state tracking
local previousMouseBehavior = nil
local previousMouseIcon = nil

local IsMobile = UserInputService.TouchEnabled and (not UserInputService.MouseEnabled or workspace.CurrentCamera.ViewportSize.Y < 500)

-- ============================================
-- MINECRAFT BORDER HELPER
-- ============================================
local function addMinecraftBorder(parent, highlightColor, shadowColor, thickness)
	local bs = thickness or BORDER_SIZE
	local top = Instance.new("Frame")
	top.Name = "BorderTop"
	top.Size = UDim2.new(1, 0, 0, bs)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = highlightColor
	top.BorderSizePixel = 0
	top.ZIndex = parent.ZIndex + 1
	top.Parent = parent
	local left = Instance.new("Frame")
	left.Name = "BorderLeft"
	left.Size = UDim2.new(0, bs, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = highlightColor
	left.BorderSizePixel = 0
	left.ZIndex = parent.ZIndex + 1
	left.Parent = parent
	local bottom = Instance.new("Frame")
	bottom.Name = "BorderBottom"
	bottom.Size = UDim2.new(1, 0, 0, bs)
	bottom.Position = UDim2.new(0, 0, 1, -bs)
	bottom.BackgroundColor3 = shadowColor
	bottom.BorderSizePixel = 0
	bottom.ZIndex = parent.ZIndex + 1
	bottom.Parent = parent
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

-- Helper: add text shadow to a text element
-- Creates shadow + foreground as children, clears parent text so shadow doesn't render on top
local function addTextShadow(parent, text, textSize, font, offsetX, offsetY)
	offsetX = offsetX or 2
	offsetY = offsetY or 2
	
	-- Store parent properties before clearing
	local textColor = parent.TextColor3
	local xAlign = parent.TextXAlignment
	local yAlign = parent.TextYAlignment
	local truncate = parent.TextTruncate
	local wrapped = parent.TextWrapped
	local useFont = font or FONT
	
	-- Clear parent text so children control rendering
	parent.TextTransparency = 1
	
	-- Shadow (behind)
	local shadow = Instance.new("TextLabel")
	shadow.Name = "TextShadow"
	shadow.Size = UDim2.new(1, 0, 1, 0)
	shadow.Position = UDim2.new(0, offsetX, 0, offsetY)
	shadow.BackgroundTransparency = 1
	shadow.Text = text
	shadow.TextColor3 = COLORS.textShadow
	shadow.TextSize = textSize
	shadow.Font = useFont
	shadow.TextXAlignment = xAlign
	shadow.TextYAlignment = yAlign
	shadow.TextTruncate = truncate
	shadow.TextWrapped = wrapped
	shadow.ZIndex = parent.ZIndex + 1
	shadow.Parent = parent
	
	-- Foreground (on top)
	local foreground = Instance.new("TextLabel")
	foreground.Name = "TextForeground"
	foreground.Size = UDim2.new(1, 0, 1, 0)
	foreground.BackgroundTransparency = 1
	foreground.Text = text
	foreground.TextColor3 = textColor
	foreground.TextSize = textSize
	foreground.Font = useFont
	foreground.TextXAlignment = xAlign
	foreground.TextYAlignment = yAlign
	foreground.TextTruncate = truncate
	foreground.TextWrapped = wrapped
	foreground.ZIndex = parent.ZIndex + 2
	foreground.Parent = parent
	
	return shadow, foreground
end

-- ============================================
-- MOUSE UTILITIES
-- ============================================
local function unlockMouse()
	previousMouseBehavior = UserInputService.MouseBehavior
	previousMouseIcon = UserInputService.MouseIconEnabled
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function lockMouse()
	if previousMouseBehavior then
		UserInputService.MouseBehavior = previousMouseBehavior
	end
	if previousMouseIcon ~= nil then
		UserInputService.MouseIconEnabled = previousMouseIcon
	end
	previousMouseBehavior = nil
	previousMouseIcon = nil
end

local function isTitleScreenOpen()
	if _G.TitleScreen and _G.TitleScreen.IsOpen then
		return _G.TitleScreen.IsOpen()
	end
	local titleScreen = playerGui:FindFirstChild("TitleScreen")
	return titleScreen and titleScreen.Enabled
end

-- ============================================
-- HELPERS
-- ============================================
local function formatTimeAgo(timestamp)
	if not timestamp then return "Never" end
	local diff = os.time() - timestamp
	if diff < 60 then return "Just now"
	elseif diff < 3600 then return math.floor(diff / 60) .. "m ago"
	elseif diff < 86400 then return math.floor(diff / 3600) .. "h ago"
	elseif diff < 604800 then return math.floor(diff / 86400) .. "d ago"
	else return os.date("%m/%d", timestamp) end
end

local pendingAutoloadMessage = nil

-- ============================================
-- RENAME DIALOG (Minecraft-style)
-- ============================================
local function showRenameDialog(slotNumber, currentName, onConfirm)
	local ui = playerGui:FindFirstChild("SaveLoadUI")
	if not ui then return end
	
	local existing = ui:FindFirstChild("RenameDialog")
	if existing then existing:Destroy() end
	
	-- Overlay
	local dialog = Instance.new("Frame")
	dialog.Name = "RenameDialog"
	dialog.Size = UDim2.new(1, 0, 1, 0)
	dialog.BackgroundColor3 = Color3.new(0, 0, 0)
	dialog.BackgroundTransparency = 0.4
	dialog.BorderSizePixel = 0
	dialog.ZIndex = 10
	dialog.Parent = ui
	
	-- Dialog box
	local box = Instance.new("Frame")
	box.Name = "Box"
	box.Size = IsMobile and UDim2.new(0.85, 0, 0, 170) or UDim2.new(0, 320, 0, 160)
	box.Position = UDim2.new(0.5, 0, 0.5, 0)
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.BackgroundColor3 = COLORS.panelBg
	box.BorderSizePixel = 0
	box.ZIndex = 11
	box.Parent = dialog
	
	if IsMobile then
		local constraint = Instance.new("UISizeConstraint")
		constraint.MaxSize = Vector2.new(380, 180)
		constraint.Parent = box
	end
	
	addMinecraftBorder(box, COLORS.panelHighlight, COLORS.panelShadow)
	
	-- Title
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 40)
	title.BackgroundTransparency = 1
	title.Text = "Rename Slot " .. slotNumber
	title.TextColor3 = COLORS.text
	title.TextSize = IsMobile and 14 or 16
	title.Font = FONT
	title.ZIndex = 12
	title.Parent = box
	addTextShadow(title, title.Text, title.TextSize, FONT)
	
	-- Text input wrapper (holds borders so they don't render inside the TextBox)
	local inputWrapper = Instance.new("Frame")
	inputWrapper.Name = "InputWrapper"
	inputWrapper.Size = UDim2.new(1, -30, 0, IsMobile and 40 or 36)
	inputWrapper.Position = UDim2.new(0, 15, 0, 44)
	inputWrapper.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	inputWrapper.BorderSizePixel = 0
	inputWrapper.ZIndex = 12
	inputWrapper.Parent = box
	addMinecraftBorder(inputWrapper, COLORS.innerShadow, COLORS.innerHighlight, 2)
	
	local inputBox = Instance.new("TextBox")
	inputBox.Name = "Input"
	inputBox.Size = UDim2.new(1, -8, 1, -4)
	inputBox.Position = UDim2.new(0, 6, 0, 2)
	inputBox.BackgroundTransparency = 1
	inputBox.BorderSizePixel = 0
	inputBox.Text = currentName
	inputBox.PlaceholderText = "Enter name..."
	inputBox.TextColor3 = COLORS.text
	inputBox.PlaceholderColor3 = COLORS.textDim
	inputBox.TextSize = IsMobile and 14 or 14
	inputBox.Font = FONT
	inputBox.ClearTextOnFocus = false
	inputBox.ZIndex = 13
	inputBox.Parent = inputWrapper
	
	-- Button row container (centered)
	local btnY = IsMobile and 100 or 96
	local btnHeight = IsMobile and 42 or 38
	local btnGap = 8
	
	local btnRow = Instance.new("Frame")
	btnRow.Name = "DialogButtons"
	btnRow.Size = UDim2.new(1, -30, 0, btnHeight)
	btnRow.Position = UDim2.new(0, 15, 0, btnY)
	btnRow.BackgroundTransparency = 1
	btnRow.ZIndex = 12
	btnRow.Parent = box
	
	-- Cancel button (left half)
	local cancelBtn = Instance.new("TextButton")
	cancelBtn.Size = UDim2.new(0.5, -btnGap/2, 1, 0)
	cancelBtn.Position = UDim2.new(0, 0, 0, 0)
	cancelBtn.BackgroundColor3 = COLORS.closeNormal
	cancelBtn.BorderSizePixel = 0
	cancelBtn.Text = ""
	cancelBtn.AutoButtonColor = false
	cancelBtn.ZIndex = 12
	cancelBtn.Parent = btnRow
	local cancelBorders = addMinecraftBorder(cancelBtn, COLORS.closeHighlight, COLORS.closeShadow)
	
	local cancelText = Instance.new("TextLabel")
	cancelText.Size = UDim2.new(1, 0, 1, 0)
	cancelText.BackgroundTransparency = 1
	cancelText.Text = "Cancel"
	cancelText.TextColor3 = COLORS.text
	cancelText.TextSize = IsMobile and 13 or 14
	cancelText.Font = FONT
	cancelText.ZIndex = 14
	cancelText.Parent = cancelBtn
	addTextShadow(cancelText, "Cancel", cancelText.TextSize, FONT)
	
	-- Save button (right half)
	local saveBtn = Instance.new("TextButton")
	saveBtn.Size = UDim2.new(0.5, -btnGap/2, 1, 0)
	saveBtn.Position = UDim2.new(0.5, btnGap/2, 0, 0)
	saveBtn.BackgroundColor3 = COLORS.saveNormal
	saveBtn.BorderSizePixel = 0
	saveBtn.Text = ""
	saveBtn.AutoButtonColor = false
	saveBtn.ZIndex = 12
	saveBtn.Parent = btnRow
	local saveBorders = addMinecraftBorder(saveBtn, COLORS.saveHighlight, COLORS.saveShadow)
	
	local saveText = Instance.new("TextLabel")
	saveText.Size = UDim2.new(1, 0, 1, 0)
	saveText.BackgroundTransparency = 1
	saveText.Text = "Save"
	saveText.TextColor3 = COLORS.text
	saveText.TextSize = IsMobile and 13 or 14
	saveText.Font = FONT
	saveText.ZIndex = 14
	saveText.Parent = saveBtn
	addTextShadow(saveText, "Save", saveText.TextSize, FONT)
	
	-- Hover effects
	cancelBtn.MouseEnter:Connect(function()
		cancelBtn.BackgroundColor3 = COLORS.closeHover
	end)
	cancelBtn.MouseLeave:Connect(function()
		cancelBtn.BackgroundColor3 = COLORS.closeNormal
	end)
	cancelBtn.MouseButton1Down:Connect(function()
		cancelBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
		cancelBorders.top.BackgroundColor3 = COLORS.closeShadow
		cancelBorders.left.BackgroundColor3 = COLORS.closeShadow
		cancelBorders.bottom.BackgroundColor3 = COLORS.closeHighlight
		cancelBorders.right.BackgroundColor3 = COLORS.closeHighlight
	end)
	cancelBtn.MouseButton1Up:Connect(function()
		cancelBtn.BackgroundColor3 = COLORS.closeHover
		cancelBorders.top.BackgroundColor3 = COLORS.closeHighlight
		cancelBorders.left.BackgroundColor3 = COLORS.closeHighlight
		cancelBorders.bottom.BackgroundColor3 = COLORS.closeShadow
		cancelBorders.right.BackgroundColor3 = COLORS.closeShadow
	end)
	
	saveBtn.MouseEnter:Connect(function()
		saveBtn.BackgroundColor3 = COLORS.saveHover
	end)
	saveBtn.MouseLeave:Connect(function()
		saveBtn.BackgroundColor3 = COLORS.saveNormal
	end)
	saveBtn.MouseButton1Down:Connect(function()
		saveBtn.BackgroundColor3 = Color3.fromRGB(40, 100, 40)
		saveBorders.top.BackgroundColor3 = COLORS.saveShadow
		saveBorders.left.BackgroundColor3 = COLORS.saveShadow
		saveBorders.bottom.BackgroundColor3 = COLORS.saveHighlight
		saveBorders.right.BackgroundColor3 = COLORS.saveHighlight
	end)
	saveBtn.MouseButton1Up:Connect(function()
		saveBtn.BackgroundColor3 = COLORS.saveHover
		saveBorders.top.BackgroundColor3 = COLORS.saveHighlight
		saveBorders.left.BackgroundColor3 = COLORS.saveHighlight
		saveBorders.bottom.BackgroundColor3 = COLORS.saveShadow
		saveBorders.right.BackgroundColor3 = COLORS.saveShadow
	end)
	
	local function closeDialog()
		dialog:Destroy()
	end
	
	cancelBtn.MouseButton1Click:Connect(closeDialog)
	dialog.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			closeDialog()
		end
	end)
	box.InputBegan:Connect(function(input)
		input.UserInputState = Enum.UserInputState.Cancel
	end)
	
	local function doSave()
		local newName = inputBox.Text:gsub("^%s*(.-)%s*$", "%1")
		if newName == "" then newName = "Slot " .. slotNumber end
		if #newName > 30 then newName = string.sub(newName, 1, 30) end
		closeDialog()
		if onConfirm then onConfirm(newName) end
	end
	
	saveBtn.MouseButton1Click:Connect(doSave)
	inputBox.FocusLost:Connect(function(enterPressed)
		if enterPressed then doSave() end
	end)
	
	task.defer(function()
		inputBox:CaptureFocus()
		inputBox.SelectionStart = 1
		inputBox.CursorPosition = #inputBox.Text + 1
	end)
end

-- ============================================
-- CLOSE UI
-- ============================================
local function closeUI()
	local ui = playerGui:FindFirstChild("SaveLoadUI")
	if ui then ui.Enabled = false end
	-- Remove blur
	if saveLoadBlur then
		TweenService:Create(saveLoadBlur, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = 0
		}):Play()
		task.delay(0.3, function()
			if saveLoadBlur then
				saveLoadBlur:Destroy()
				saveLoadBlur = nil
			end
		end)
	end
	lockMouse()
	selectedSlot = nil
	slotData = nil
	slotFrames = {}
end

-- ============================================
-- CREATE MINECRAFT-STYLE BUTTON
-- ============================================
local function createMCButton(name, text, parent, size, layoutOrder, colorSet)
	colorSet = colorSet or {
		normal = COLORS.buttonNormal,
		hover = COLORS.buttonHover,
		highlight = COLORS.buttonHighlight,
		shadow = COLORS.buttonShadow,
	}
	
	local button = Instance.new("TextButton")
	button.Name = name
	button.Size = size
	button.BackgroundColor3 = colorSet.normal
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	if layoutOrder then button.LayoutOrder = layoutOrder end
	button.Parent = parent
	
	local borders = addMinecraftBorder(button, colorSet.highlight, colorSet.shadow)
	
	-- Text foreground
	local fg = Instance.new("TextLabel")
	fg.Name = "TextForeground"
	fg.Size = UDim2.new(1, 0, 1, 0)
	fg.BackgroundTransparency = 1
	fg.Text = text
	fg.TextColor3 = COLORS.text
	fg.TextSize = IsMobile and 13 or 15
	fg.Font = FONT
	fg.ZIndex = button.ZIndex + 2
	fg.Parent = button
	
	-- Text shadow
	local sh = Instance.new("TextLabel")
	sh.Name = "TextShadow"
	sh.Size = UDim2.new(1, 0, 1, 0)
	sh.Position = UDim2.new(0, 2, 0, 2)
	sh.BackgroundTransparency = 1
	sh.Text = text
	sh.TextColor3 = COLORS.textShadow
	sh.TextSize = IsMobile and 13 or 15
	sh.Font = FONT
	sh.ZIndex = button.ZIndex + 1
	sh.Parent = button
	
	-- Hover/press effects
	button.MouseEnter:Connect(function()
		if button:GetAttribute("Disabled") then return end
		button.BackgroundColor3 = colorSet.hover
		borders.top.BackgroundColor3 = Color3.new(
			math.min(colorSet.highlight.R + 0.08, 1),
			math.min(colorSet.highlight.G + 0.08, 1),
			math.min(colorSet.highlight.B + 0.08, 1)
		)
		borders.left.BackgroundColor3 = borders.top.BackgroundColor3
	end)
	button.MouseLeave:Connect(function()
		if button:GetAttribute("Disabled") then return end
		button.BackgroundColor3 = colorSet.normal
		borders.top.BackgroundColor3 = colorSet.highlight
		borders.left.BackgroundColor3 = colorSet.highlight
		borders.bottom.BackgroundColor3 = colorSet.shadow
		borders.right.BackgroundColor3 = colorSet.shadow
	end)
	button.MouseButton1Down:Connect(function()
		if button:GetAttribute("Disabled") then return end
		button.BackgroundColor3 = Color3.new(
			math.max(colorSet.normal.R - 0.08, 0),
			math.max(colorSet.normal.G - 0.08, 0),
			math.max(colorSet.normal.B - 0.08, 0)
		)
		borders.top.BackgroundColor3 = colorSet.shadow
		borders.left.BackgroundColor3 = colorSet.shadow
		borders.bottom.BackgroundColor3 = colorSet.highlight
		borders.right.BackgroundColor3 = colorSet.highlight
	end)
	button.MouseButton1Up:Connect(function()
		if button:GetAttribute("Disabled") then return end
		button.BackgroundColor3 = colorSet.hover
		borders.top.BackgroundColor3 = colorSet.highlight
		borders.left.BackgroundColor3 = colorSet.highlight
		borders.bottom.BackgroundColor3 = colorSet.shadow
		borders.right.BackgroundColor3 = colorSet.shadow
	end)
	
	return button, borders, fg, sh
end

-- Helper to set button text
local function setButtonText(button, text)
	local fg = button:FindFirstChild("TextForeground")
	local sh = button:FindFirstChild("TextShadow")
	if fg then fg.Text = text end
	if sh then sh.Text = text end
end

-- Helper to set button disabled state
local function setButtonDisabled(button, disabled)
	button:SetAttribute("Disabled", disabled)
	if disabled then
		button.BackgroundColor3 = COLORS.buttonDisabled
		-- Grey out borders
		for _, child in button:GetChildren() do
			if child.Name == "BorderTop" or child.Name == "BorderLeft" then
				child.BackgroundColor3 = COLORS.buttonDisabledHighlight
			elseif child.Name == "BorderBottom" or child.Name == "BorderRight" then
				child.BackgroundColor3 = COLORS.buttonDisabledShadow
			end
		end
		local fg = button:FindFirstChild("TextForeground")
		if fg then fg.TextColor3 = COLORS.textDisabled end
	else
		-- Restore from the colorSet stored as attribute
		local fg = button:FindFirstChild("TextForeground")
		if fg then fg.TextColor3 = COLORS.text end
	end
end

-- ============================================
-- CREATE SLOT FRAME (Minecraft-style)
-- ============================================
local function createSlotFrame(parent, slotNumber, slotInfo, isLocked)
	local isEmpty = not slotInfo
	
	local frame = Instance.new("TextButton")
	frame.Name = "Slot" .. slotNumber
	frame.Size = UDim2.new(1, -12, 0, IsMobile and 52 or 70)
	frame.BackgroundColor3 = isEmpty and COLORS.slotEmpty or COLORS.slotFilled
	frame.BorderSizePixel = 0
	frame.AutoButtonColor = false
	frame.Text = ""
	frame.Parent = parent
	
	local borders = addMinecraftBorder(frame, COLORS.slotHighlight, COLORS.slotShadow, 2)
	frame:SetAttribute("_borders", true) -- Tag for later
	
	-- Store borders on the frame for selection updates
	frame:SetAttribute("BordersTag", true)
	-- We'll store border refs in a module-level table instead
	
	-- Slot number badge
	local badge = Instance.new("Frame")
	badge.Name = "SlotBadge"
	badge.Size = UDim2.new(0, IsMobile and 30 or 35, 0, IsMobile and 30 or 35)
	badge.Position = UDim2.new(0, 8, 0.5, 0)
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.BackgroundColor3 = isEmpty and COLORS.badgeEmpty or COLORS.badgeFilled
	badge.BorderSizePixel = 0
	badge.Parent = frame
	addMinecraftBorder(badge, 
		isEmpty and Color3.fromRGB(70, 70, 75) or Color3.fromRGB(75, 100, 125),
		isEmpty and Color3.fromRGB(30, 30, 35) or Color3.fromRGB(30, 45, 60),
		2
	)
	
	local numLabel = Instance.new("TextLabel")
	numLabel.Size = UDim2.new(1, 0, 1, 0)
	numLabel.BackgroundTransparency = 1
	numLabel.Text = tostring(slotNumber)
	numLabel.TextColor3 = COLORS.text
	numLabel.TextSize = IsMobile and 14 or 16
	numLabel.Font = FONT
	numLabel.ZIndex = badge.ZIndex + 2
	numLabel.Parent = badge
	addTextShadow(numLabel, tostring(slotNumber), numLabel.TextSize, FONT, 1, 1)
	
	-- Content area
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, -(IsMobile and 50 or 60), 1, -8)
	content.Position = UDim2.new(0, IsMobile and 46 or 52, 0, 4)
	content.BackgroundTransparency = 1
	content.Parent = frame
	
	if isLocked then
		local lockLabel = Instance.new("TextLabel")
		lockLabel.Size = UDim2.new(1, 0, 0, 22)
		lockLabel.Position = UDim2.new(0, 0, 0, 8)
		lockLabel.BackgroundTransparency = 1
		lockLabel.Text = "Locked"
		lockLabel.TextColor3 = COLORS.textDim
		lockLabel.TextSize = IsMobile and 13 or 14
		lockLabel.Font = FONT
		lockLabel.TextXAlignment = Enum.TextXAlignment.Left
		lockLabel.Parent = content
		addTextShadow(lockLabel, "Locked", lockLabel.TextSize, FONT, 1, 1)
		
		local priceLabel = Instance.new("TextLabel")
		priceLabel.Size = UDim2.new(1, 0, 0, 18)
		priceLabel.Position = UDim2.new(0, 0, 0, 30)
		priceLabel.BackgroundTransparency = 1
		priceLabel.Text = ROBUX_ICON .. SLOT_PRICE_ROBUX .. " or " .. SLOT_PRICE_COINS .. " coins"
		priceLabel.TextColor3 = COLORS.textWarning
		priceLabel.TextSize = IsMobile and 10 or 11
		priceLabel.Font = FONT
		priceLabel.TextXAlignment = Enum.TextXAlignment.Left
		priceLabel.Parent = content
		
		frame.BackgroundColor3 = Color3.fromRGB(50, 45, 40)
		borders.top.BackgroundColor3 = Color3.fromRGB(75, 68, 60)
		borders.left.BackgroundColor3 = Color3.fromRGB(75, 68, 60)
		borders.bottom.BackgroundColor3 = Color3.fromRGB(28, 25, 22)
		borders.right.BackgroundColor3 = Color3.fromRGB(28, 25, 22)
	elseif isEmpty then
		local emptyLabel = Instance.new("TextLabel")
		emptyLabel.Size = UDim2.new(1, 0, 0, 22)
		emptyLabel.Position = UDim2.new(0, 0, 0, 8)
		emptyLabel.BackgroundTransparency = 1
		emptyLabel.Text = "Empty Slot"
		emptyLabel.TextColor3 = COLORS.textDim
		emptyLabel.TextSize = IsMobile and 13 or 14
		emptyLabel.Font = FONT
		emptyLabel.TextXAlignment = Enum.TextXAlignment.Left
		emptyLabel.Parent = content
		addTextShadow(emptyLabel, "Empty Slot", emptyLabel.TextSize, FONT, 1, 1)
		
		local hintLabel = Instance.new("TextLabel")
		hintLabel.Size = UDim2.new(1, 0, 0, 16)
		hintLabel.Position = UDim2.new(0, 0, 0, 30)
		hintLabel.BackgroundTransparency = 1
		hintLabel.Text = "Save here or Load for fresh plot"
		hintLabel.TextColor3 = Color3.fromRGB(100, 100, 100)
		hintLabel.TextSize = IsMobile and 9 or 10
		hintLabel.Font = FONT
		hintLabel.TextXAlignment = Enum.TextXAlignment.Left
		hintLabel.Parent = content
	else
		-- Title
		local titleLabel = Instance.new("TextLabel")
		titleLabel.Name = "Title"
		titleLabel.Size = UDim2.new(1, -60, 0, 20)
		titleLabel.Position = UDim2.new(0, 0, 0, IsMobile and 2 or 4)
		titleLabel.BackgroundTransparency = 1
		titleLabel.Text = slotInfo.name or ((slotInfo.biome or "Unknown") .. " Build")
		titleLabel.TextColor3 = COLORS.text
		titleLabel.TextSize = IsMobile and 11 or 13
		titleLabel.Font = FONT
		titleLabel.TextXAlignment = Enum.TextXAlignment.Left
		titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
		titleLabel.Parent = content
		addTextShadow(titleLabel, titleLabel.Text, titleLabel.TextSize, FONT, 1, 1)
		
		-- Edit button (Minecraft-style small button)
		local editBtn = Instance.new("TextButton")
		editBtn.Name = "EditButton"
		editBtn.Size = UDim2.new(0, IsMobile and 36 or 42, 0, IsMobile and 16 or 18)
		editBtn.Position = UDim2.new(1, IsMobile and -40 or -46, 0, 5)
		editBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
		editBtn.BorderSizePixel = 0
		editBtn.Text = ""
		editBtn.AutoButtonColor = false
		editBtn.Parent = content
		addMinecraftBorder(editBtn, Color3.fromRGB(100, 100, 100), Color3.fromRGB(40, 40, 40), 1)
		
		local editText = Instance.new("TextLabel")
		editText.Size = UDim2.new(1, 0, 1, 0)
		editText.BackgroundTransparency = 1
		editText.Text = "Edit"
		editText.TextColor3 = COLORS.textDim
		editText.TextSize = IsMobile and 9 or 10
		editText.Font = FONT
		editText.ZIndex = editBtn.ZIndex + 2
		editText.Parent = editBtn
		
		editBtn.MouseEnter:Connect(function()
			editBtn.BackgroundColor3 = Color3.fromRGB(90, 90, 90)
		end)
		editBtn.MouseLeave:Connect(function()
			editBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
		end)
		
		frame:SetAttribute("SlotNumber", slotNumber)
		
		-- Block count
		local blocksLabel = Instance.new("TextLabel")
		blocksLabel.Size = UDim2.new(0.5, 0, 0, 16)
		blocksLabel.Position = UDim2.new(0, 0, 0, IsMobile and 18 or 24)
		blocksLabel.BackgroundTransparency = 1
		blocksLabel.Text = (slotInfo.blockCount or 0) .. " blocks"
		blocksLabel.TextColor3 = COLORS.textDim
		blocksLabel.TextSize = IsMobile and 9 or 10
		blocksLabel.Font = FONT
		blocksLabel.TextXAlignment = Enum.TextXAlignment.Left
		blocksLabel.Parent = content
		
		-- Terrain style
		local terrainLabel = Instance.new("TextLabel")
		terrainLabel.Size = UDim2.new(0.5, 0, 0, 16)
		terrainLabel.Position = UDim2.new(0.5, 0, 0, IsMobile and 18 or 24)
		terrainLabel.BackgroundTransparency = 1
		terrainLabel.Text = slotInfo.terrainStyle or "Flat"
		terrainLabel.TextColor3 = COLORS.textDim
		terrainLabel.TextSize = IsMobile and 9 or 10
		terrainLabel.Font = FONT
		terrainLabel.TextXAlignment = Enum.TextXAlignment.Left
		terrainLabel.Parent = content
		
		-- Time ago
		local timeLabel = Instance.new("TextLabel")
		timeLabel.Size = UDim2.new(0.5, 0, 0, 16)
		timeLabel.Position = UDim2.new(0, 0, 0, IsMobile and 32 or 40)
		timeLabel.BackgroundTransparency = 1
		timeLabel.Text = formatTimeAgo(slotInfo.lastSaved)
		timeLabel.TextColor3 = COLORS.textDim
		timeLabel.TextSize = IsMobile and 9 or 10
		timeLabel.Font = FONT
		timeLabel.TextXAlignment = Enum.TextXAlignment.Left
		timeLabel.Parent = content
	end
	
	return frame, borders, not isLocked
end

-- ============================================
-- SLOT SELECTION
-- ============================================
local slotBordersMap = {} -- slotNumber -> borders table

local function updateSlotSelection(newSelectedSlot, ui)
	selectedSlot = newSelectedSlot
	
	for slotNum, data in pairs(slotFrames) do
		local frame = data.frame
		local slotInfo = data.slotInfo
		local isEmpty = not slotInfo
		local borders = slotBordersMap[slotNum]
		
		if slotNum == selectedSlot then
			frame.BackgroundColor3 = COLORS.slotSelected
			if borders then
				borders.top.BackgroundColor3 = COLORS.slotSelectedHighlight
				borders.left.BackgroundColor3 = COLORS.slotSelectedHighlight
				borders.bottom.BackgroundColor3 = COLORS.slotSelectedShadow
				borders.right.BackgroundColor3 = COLORS.slotSelectedShadow
			end
		else
			frame.BackgroundColor3 = isEmpty and COLORS.slotEmpty or COLORS.slotFilled
			if borders then
				borders.top.BackgroundColor3 = COLORS.slotHighlight
				borders.left.BackgroundColor3 = COLORS.slotHighlight
				borders.bottom.BackgroundColor3 = COLORS.slotShadow
				borders.right.BackgroundColor3 = COLORS.slotShadow
			end
		end
	end
	
	-- Update action buttons based on selection
	if ui then
		local panel = ui:FindFirstChild("Panel")
		local buttonRow = panel and panel:FindFirstChild("ButtonRow")
		if buttonRow then
			local saveBtn = buttonRow:FindFirstChild("SaveButton")
			local loadBtn = buttonRow:FindFirstChild("LoadButton")
			local deleteBtn = buttonRow:FindFirstChild("DeleteButton")
			
			local hasData = selectedSlot and slotFrames[selectedSlot] and slotFrames[selectedSlot].slotInfo
			
			if saveBtn then
				if selectedSlot then
					setButtonDisabled(saveBtn, false)
					saveBtn.BackgroundColor3 = COLORS.saveNormal
					-- Restore save borders
					for _, child in saveBtn:GetChildren() do
						if child.Name == "BorderTop" or child.Name == "BorderLeft" then
							child.BackgroundColor3 = COLORS.saveHighlight
						elseif child.Name == "BorderBottom" or child.Name == "BorderRight" then
							child.BackgroundColor3 = COLORS.saveShadow
						end
					end
				else
					setButtonDisabled(saveBtn, true)
				end
			end
			if loadBtn then
				if selectedSlot then
					setButtonDisabled(loadBtn, false)
					loadBtn.BackgroundColor3 = COLORS.loadNormal
					for _, child in loadBtn:GetChildren() do
						if child.Name == "BorderTop" or child.Name == "BorderLeft" then
							child.BackgroundColor3 = COLORS.loadHighlight
						elseif child.Name == "BorderBottom" or child.Name == "BorderRight" then
							child.BackgroundColor3 = COLORS.loadShadow
						end
					end
				else
					setButtonDisabled(loadBtn, true)
				end
			end
			if deleteBtn then
				if hasData then
					setButtonDisabled(deleteBtn, false)
					deleteBtn.BackgroundColor3 = COLORS.deleteNormal
					for _, child in deleteBtn:GetChildren() do
						if child.Name == "BorderTop" or child.Name == "BorderLeft" then
							child.BackgroundColor3 = COLORS.deleteHighlight
						elseif child.Name == "BorderBottom" or child.Name == "BorderRight" then
							child.BackgroundColor3 = COLORS.deleteShadow
						end
					end
				else
					setButtonDisabled(deleteBtn, true)
				end
			end
			-- Restore Auto: only enabled when this slot has an autosave snapshot
			-- (slotInfo.autosaveTime is set server-side once the autosave loop has run).
			local restoreBtn = buttonRow:FindFirstChild("RestoreAutoButton")
			if restoreBtn then
				local selInfo = selectedSlot and slotFrames[selectedSlot] and slotFrames[selectedSlot].slotInfo
				local hasAutosave = selInfo and selInfo.autosaveTime ~= nil
				if hasAutosave then
					setButtonDisabled(restoreBtn, false)
					restoreBtn.BackgroundColor3 = COLORS.autosaveNormal
					for _, child in restoreBtn:GetChildren() do
						if child.Name == "BorderTop" or child.Name == "BorderLeft" then
							child.BackgroundColor3 = COLORS.autosaveHighlight
						elseif child.Name == "BorderBottom" or child.Name == "BorderRight" then
							child.BackgroundColor3 = COLORS.autosaveShadow
						end
					end
				else
					setButtonDisabled(restoreBtn, true)
				end
			end
		end
	end
end

-- ============================================
-- CREATE MAIN UI
-- ============================================
local function createUI()
	local existing = playerGui:FindFirstChild("SaveLoadUI")
	if existing then existing:Destroy() end
	
	slotFrames = {}
	slotBordersMap = {}
	
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SaveLoadUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 100
	screenGui.ScreenInsets = Enum.ScreenInsets.None
	screenGui.Enabled = false
	screenGui.Parent = playerGui
	
	-- Transparent click-catcher overlay (blur handles the dimming)
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.new(0, 0, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Parent = screenGui
	
	-- Main panel
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	if IsMobile then
		panel.Size = UDim2.new(0.88, 0, 0.82, 0)
	else
		panel.Size = UDim2.new(0, 400, 0, 460)
	end
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.BackgroundColor3 = COLORS.panelBg
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = true
	panel.Parent = screenGui
	
	if IsMobile then
		local sizeConstraint = Instance.new("UISizeConstraint")
		sizeConstraint.MaxSize = Vector2.new(520, 400)
		sizeConstraint.Parent = panel
	end
	
	addMinecraftBorder(panel, COLORS.panelHighlight, COLORS.panelShadow)
	
	-- ===== TITLE =====
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, IsMobile and 22 or 40)
	title.Position = UDim2.new(0, 0, 0, IsMobile and 4 or 0)
	title.BackgroundTransparency = 1
	title.Text = "Save Slots"
	title.TextColor3 = COLORS.text
	title.TextSize = IsMobile and 16 or 20
	title.Font = FONT
	title.Parent = panel
	addTextShadow(title, "Save Slots", title.TextSize, FONT)
	
	-- ===== STATUS =====
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.Size = UDim2.new(1, -20, 0, 16)
	status.Position = UDim2.new(0, 10, 0, IsMobile and 22 or 38)
	status.BackgroundTransparency = 1
	status.Text = "Select a slot to save or load"
	status.TextColor3 = COLORS.textDim
	status.TextSize = IsMobile and 9 or 12
	status.Font = FONT
	status.TextXAlignment = Enum.TextXAlignment.Center
	status.Parent = panel
	
	if IsMobile then
		-- ===== MOBILE LAYOUT: Side-by-side =====
		
		-- Left: Slots wrapper (holds borders so they don't interfere with UIListLayout)
		local slotsWrapper = Instance.new("Frame")
		slotsWrapper.Name = "SlotsWrapper"
		slotsWrapper.Size = UDim2.new(1, -106, 1, -42)
		slotsWrapper.Position = UDim2.new(0, 6, 0, 36)
		slotsWrapper.BackgroundColor3 = COLORS.innerBg
		slotsWrapper.BorderSizePixel = 0
		slotsWrapper.Parent = panel
		addMinecraftBorder(slotsWrapper, COLORS.innerHighlight, COLORS.innerShadow, 2)
		
		local slotsContainer = Instance.new("ScrollingFrame")
		slotsContainer.Name = "SlotsContainer"
		slotsContainer.Size = UDim2.new(1, -4, 1, -4)
		slotsContainer.Position = UDim2.new(0, 2, 0, 2)
		slotsContainer.BackgroundTransparency = 1
		slotsContainer.BorderSizePixel = 0
		slotsContainer.ScrollBarThickness = 4
		slotsContainer.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 85)
		slotsContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
		slotsContainer.Parent = slotsWrapper
		
		local slotsLayout = Instance.new("UIListLayout")
		slotsLayout.Padding = UDim.new(0, 5)
		slotsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		slotsLayout.Parent = slotsContainer
		
		local slotsPadding = Instance.new("UIPadding")
		slotsPadding.PaddingTop = UDim.new(0, 6)
		slotsPadding.PaddingBottom = UDim.new(0, 6)
		slotsPadding.Parent = slotsContainer
		
		-- Right: Button column
		local buttonColumn = Instance.new("Frame")
		buttonColumn.Name = "ButtonRow"
		buttonColumn.Size = UDim2.new(0, 88, 1, -42)
		buttonColumn.Position = UDim2.new(1, -94, 0, 36)
		buttonColumn.BackgroundTransparency = 1
		buttonColumn.Parent = panel
		
		local buttonLayout = Instance.new("UIListLayout")
		buttonLayout.FillDirection = Enum.FillDirection.Vertical
		buttonLayout.Padding = UDim.new(0, 4)
		buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
		buttonLayout.Parent = buttonColumn
		
		local btnSize = UDim2.new(1, 0, 0, 38)
		
		createMCButton("SaveButton", "Save", buttonColumn, btnSize, 1, {
			normal = COLORS.saveNormal, hover = COLORS.saveHover,
			highlight = COLORS.saveHighlight, shadow = COLORS.saveShadow,
		})
		createMCButton("LoadButton", "Load", buttonColumn, btnSize, 2, {
			normal = COLORS.loadNormal, hover = COLORS.loadHover,
			highlight = COLORS.loadHighlight, shadow = COLORS.loadShadow,
		})
		createMCButton("RestoreAutoButton", "Restore Auto", buttonColumn, btnSize, 3, {
			normal = COLORS.autosaveNormal, hover = COLORS.autosaveHover,
			highlight = COLORS.autosaveHighlight, shadow = COLORS.autosaveShadow,
		})
		createMCButton("DeleteButton", "Delete", buttonColumn, btnSize, 4, {
			normal = COLORS.deleteNormal, hover = COLORS.deleteHover,
			highlight = COLORS.deleteHighlight, shadow = COLORS.deleteShadow,
		})
		
		local purchaseRobuxBtn = createMCButton("PurchaseRobux", "Buy (" .. ROBUX_ICON .. SLOT_PRICE_ROBUX .. ")", buttonColumn, btnSize, 5, {
			normal = COLORS.purchaseRobuxNormal, hover = COLORS.purchaseRobuxHover,
			highlight = COLORS.purchaseRobuxHighlight, shadow = COLORS.purchaseRobuxShadow,
		})
		purchaseRobuxBtn.Visible = false
		
		local purchaseCoinsBtn = createMCButton("PurchaseCoins", SLOT_PRICE_COINS .. " Coins", buttonColumn, btnSize, 6, {
			normal = COLORS.purchaseNormal, hover = COLORS.purchaseHover,
			highlight = COLORS.purchaseHighlight, shadow = COLORS.purchaseShadow,
		})
		purchaseCoinsBtn.Visible = false
		
		createMCButton("CloseButton", "Close", buttonColumn, btnSize, 7, {
			normal = COLORS.closeNormal, hover = COLORS.closeHover,
			highlight = COLORS.closeHighlight, shadow = COLORS.closeShadow,
		})
	else
		-- ===== DESKTOP LAYOUT =====
		
		-- Slots wrapper (holds borders so they don't interfere with UIListLayout)
		local slotsWrapper = Instance.new("Frame")
		slotsWrapper.Name = "SlotsWrapper"
		slotsWrapper.Size = UDim2.new(1, -20, 1, -242)
		slotsWrapper.Position = UDim2.new(0, 10, 0, 58)
		slotsWrapper.BackgroundColor3 = COLORS.innerBg
		slotsWrapper.BorderSizePixel = 0
		slotsWrapper.Parent = panel
		addMinecraftBorder(slotsWrapper, COLORS.innerHighlight, COLORS.innerShadow, 2)
		
		local slotsContainer = Instance.new("ScrollingFrame")
		slotsContainer.Name = "SlotsContainer"
		slotsContainer.Size = UDim2.new(1, -4, 1, -4)
		slotsContainer.Position = UDim2.new(0, 2, 0, 2)
		slotsContainer.BackgroundTransparency = 1
		slotsContainer.BorderSizePixel = 0
		slotsContainer.ScrollBarThickness = 5
		slotsContainer.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 85)
		slotsContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
		slotsContainer.Parent = slotsWrapper
		
		local slotsLayout = Instance.new("UIListLayout")
		slotsLayout.Padding = UDim.new(0, 6)
		slotsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		slotsLayout.Parent = slotsContainer
		
		local slotsPadding = Instance.new("UIPadding")
		slotsPadding.PaddingTop = UDim.new(0, 8)
		slotsPadding.PaddingBottom = UDim.new(0, 8)
		slotsPadding.Parent = slotsContainer
		
		-- Button grid (2 columns x 2 rows): Save, Load / Restore, Delete.
		-- All four stay direct children of ButtonRow so existing lookups still resolve;
		-- a UIGridLayout wraps them into two rows without nested frames.
		local buttonRow = Instance.new("Frame")
		buttonRow.Name = "ButtonRow"
		buttonRow.Size = UDim2.new(0, 366, 0, 86)
		buttonRow.Position = UDim2.new(0.5, 0, 1, -180)
		buttonRow.AnchorPoint = Vector2.new(0.5, 0)
		buttonRow.BackgroundTransparency = 1
		buttonRow.Parent = panel
		
		local buttonLayout = Instance.new("UIGridLayout")
		buttonLayout.CellSize = UDim2.new(0, 180, 0, 40)
		buttonLayout.CellPadding = UDim2.new(0, 6, 0, 6)
		buttonLayout.FillDirectionMaxCells = 2 -- 2 per row -> wraps to a second row
		buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Top
		buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
		buttonLayout.Parent = buttonRow
		
		local btnSize = UDim2.new(0, 180, 0, 40) -- ignored by UIGridLayout but kept for clarity
		
		createMCButton("SaveButton", "Save", buttonRow, btnSize, 1, {
			normal = COLORS.saveNormal, hover = COLORS.saveHover,
			highlight = COLORS.saveHighlight, shadow = COLORS.saveShadow,
		})
		createMCButton("LoadButton", "Load", buttonRow, btnSize, 2, {
			normal = COLORS.loadNormal, hover = COLORS.loadHover,
			highlight = COLORS.loadHighlight, shadow = COLORS.loadShadow,
		})
		createMCButton("RestoreAutoButton", "Restore Auto", buttonRow, btnSize, 3, {
			normal = COLORS.autosaveNormal, hover = COLORS.autosaveHover,
			highlight = COLORS.autosaveHighlight, shadow = COLORS.autosaveShadow,
		})
		createMCButton("DeleteButton", "Delete", buttonRow, btnSize, 4, {
			normal = COLORS.deleteNormal, hover = COLORS.deleteHover,
			highlight = COLORS.deleteHighlight, shadow = COLORS.deleteShadow,
		})
		
		-- Purchase buttons row (two side-by-side: Robux green + Coins yellow)
		local purchaseRow = Instance.new("Frame")
		purchaseRow.Name = "PurchaseRow"
		purchaseRow.Size = UDim2.new(0, 366, 0, 38)
		purchaseRow.Position = UDim2.new(0.5, 0, 1, -88)
		purchaseRow.AnchorPoint = Vector2.new(0.5, 0)
		purchaseRow.BackgroundTransparency = 1
		purchaseRow.Visible = false
		purchaseRow.Parent = panel
		
		local purchaseRobuxBtn = createMCButton("PurchaseRobux", ROBUX_ICON .. SLOT_PRICE_ROBUX .. " Robux", purchaseRow,
			UDim2.new(0, 180, 0, 38), nil, {
				normal = COLORS.purchaseRobuxNormal, hover = COLORS.purchaseRobuxHover,
				highlight = COLORS.purchaseRobuxHighlight, shadow = COLORS.purchaseRobuxShadow,
			})
		purchaseRobuxBtn.Position = UDim2.new(0, 0, 0, 0)
		
		local purchaseCoinsBtn = createMCButton("PurchaseCoins", SLOT_PRICE_COINS .. " Coins", purchaseRow,
			UDim2.new(0, 180, 0, 38), nil, {
				normal = COLORS.purchaseNormal, hover = COLORS.purchaseHover,
				highlight = COLORS.purchaseHighlight, shadow = COLORS.purchaseShadow,
			})
		purchaseCoinsBtn.Position = UDim2.new(1, -180, 0, 0)
		
		-- Close button (matched to button row width)
		local closeBtn = createMCButton("CloseButton", "Close", panel,
			UDim2.new(0, 366, 0, 38), nil, {
				normal = COLORS.closeNormal, hover = COLORS.closeHover,
				highlight = COLORS.closeHighlight, shadow = COLORS.closeShadow,
			})
		closeBtn.Position = UDim2.new(0.5, 0, 1, -44)
		closeBtn.AnchorPoint = Vector2.new(0.5, 0)
	end
	
	return screenGui
end

-- ============================================
-- POPULATE SLOTS
-- ============================================
local function populateSlots(ui, data)
	slotData = data
	slotFrames = {}
	slotBordersMap = {}
	
	local slotsWrapper = ui.Panel:FindFirstChild("SlotsWrapper")
	local slotsContainer = slotsWrapper and slotsWrapper:FindFirstChild("SlotsContainer")
	
	for _, child in ipairs(slotsContainer:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	
	local maxSlots = data.maxSlots or 3
	local totalHeight = 0
	local activeSlot = data.activeSlot or 1
	local slotHeight = IsMobile and 52 or 70
	
	for i = 1, maxSlots do
		local slotInfo = data.slots[i]
		local frame, borders, isSelectable = createSlotFrame(slotsContainer, i, slotInfo, false)
		
		slotBordersMap[i] = borders
		slotFrames[i] = {
			frame = frame,
			slotInfo = slotInfo,
			isSelectable = isSelectable,
		}
		
		frame.MouseButton1Click:Connect(function()
			if isProcessing then return end
			if isSelectable then
				updateSlotSelection(i, ui)
			end
		end)
		
		frame.MouseEnter:Connect(function()
			if i ~= selectedSlot and isSelectable and not isProcessing then
				frame.BackgroundColor3 = COLORS.slotHover
			end
		end)
		frame.MouseLeave:Connect(function()
			if i ~= selectedSlot and isSelectable and not isProcessing then
				local isEmpty = not slotFrames[i].slotInfo
				frame.BackgroundColor3 = isEmpty and COLORS.slotEmpty or COLORS.slotFilled
			end
		end)
		
		-- Connect edit button
		if slotInfo then
			local content = frame:FindFirstChild("Content")
			local editBtn = content and content:FindFirstChild("EditButton")
			if editBtn then
				editBtn.MouseButton1Click:Connect(function()
					if isProcessing then return end
					local currentName = slotInfo.name or ("Slot " .. i)
					showRenameDialog(i, currentName, function(newName)
						RenameSlot:FireServer(i, newName)
					end)
				end)
			end
		end
		
		totalHeight = totalHeight + slotHeight + 6
	end
	
	-- Show purchase buttons if they can buy more
	local buttonRow = ui.Panel:FindFirstChild("ButtonRow")
	local canBuyMore = maxSlots < 20
	-- Desktop: PurchaseRow contains both buttons
	local purchaseRow = ui.Panel:FindFirstChild("PurchaseRow")
	if purchaseRow then
		purchaseRow.Visible = canBuyMore
	end
	-- Mobile: buttons are in ButtonRow directly
	if buttonRow then
		local robuxBtn = buttonRow:FindFirstChild("PurchaseRobux")
		local coinsBtn = buttonRow:FindFirstChild("PurchaseCoins")
		if robuxBtn then robuxBtn.Visible = canBuyMore end
		if coinsBtn then coinsBtn.Visible = canBuyMore end
	end
	
	slotsContainer.CanvasSize = UDim2.new(0, 0, 0, totalHeight + 16)
	
	if activeSlot and slotFrames[activeSlot] then
		updateSlotSelection(activeSlot, ui)
	elseif slotFrames[1] then
		updateSlotSelection(1, ui)
	end
end

-- ============================================
-- BUTTON INTERACTIONS
-- ============================================
local function setupButtons(ui, activeSlot)
	local panel = ui.Panel
	local buttonRow = panel.ButtonRow
	local saveBtn = buttonRow.SaveButton
	local loadBtn = buttonRow.LoadButton
	local deleteBtn = buttonRow.DeleteButton
	local purchaseRow = panel:FindFirstChild("PurchaseRow")
	local purchaseRobuxBtn = (purchaseRow and purchaseRow:FindFirstChild("PurchaseRobux")) or buttonRow:FindFirstChild("PurchaseRobux")
	local purchaseCoinsBtn = (purchaseRow and purchaseRow:FindFirstChild("PurchaseCoins")) or buttonRow:FindFirstChild("PurchaseCoins")
	local closeBtn = buttonRow:FindFirstChild("CloseButton") or panel:FindFirstChild("CloseButton")
	local status = panel.Status
	
	-- Save
	saveBtn.MouseButton1Click:Connect(function()
		if isProcessing or not selectedSlot then return end
		if saveBtn:GetAttribute("Disabled") then return end
		
		isProcessing = true
		setButtonText(saveBtn, "Saving...")
		status.Text = "Saving to Slot " .. selectedSlot .. "..."
		status.TextColor3 = COLORS.textDim
		
		SavePlot:FireServer(selectedSlot)
	end)
	
	-- Load
	loadBtn.MouseButton1Click:Connect(function()
		if isProcessing or not selectedSlot then return end
		if loadBtn:GetAttribute("Disabled") then return end
		
		local slotInfo = slotFrames[selectedSlot] and slotFrames[selectedSlot].slotInfo
		local loadMessage = slotInfo and ("Loading Slot " .. selectedSlot .. "...") or ("Loading fresh plot...")
		
		isProcessing = true
		setButtonText(loadBtn, "Loading...")
		status.Text = loadMessage
		status.TextColor3 = COLORS.textDim
		
		LoadPlot:FireServer(selectedSlot)
	end)
	
	-- Restore Auto (with confirmation) -- loads the independent autosave snapshot
	local restoreBtn = buttonRow:FindFirstChild("RestoreAutoButton")
	local restoreConfirmPending = false
	if restoreBtn then
		restoreBtn.MouseButton1Click:Connect(function()
			if isProcessing or not selectedSlot then return end
			if restoreBtn:GetAttribute("Disabled") then return end
			
			local slotInfo = slotFrames[selectedSlot] and slotFrames[selectedSlot].slotInfo
			if not (slotInfo and slotInfo.autosaveTime) then return end
			
			if not restoreConfirmPending then
				restoreConfirmPending = true
				setButtonText(restoreBtn, "Confirm?")
				status.Text = "Restore autosave from " .. formatTimeAgo(slotInfo.autosaveTime) .. "? Click again."
				status.TextColor3 = COLORS.textWarning
				
				task.delay(4, function()
					if restoreConfirmPending then
						restoreConfirmPending = false
						setButtonText(restoreBtn, "Restore Auto")
						status.Text = "Select a slot to save or load"
						status.TextColor3 = COLORS.textDim
					end
				end)
			else
				restoreConfirmPending = false
				isProcessing = true
				setButtonText(restoreBtn, "Restoring...")
				status.Text = "Restoring autosave for Slot " .. selectedSlot .. "..."
				status.TextColor3 = COLORS.textDim
				
				LoadAutosave:FireServer(selectedSlot)
			end
		end)
	end
	
	-- Delete (with confirmation)
	local deleteConfirmPending = false
	deleteBtn.MouseButton1Click:Connect(function()
		if isProcessing or not selectedSlot then return end
		if deleteBtn:GetAttribute("Disabled") then return end
		
		local slotInfo = slotFrames[selectedSlot] and slotFrames[selectedSlot].slotInfo
		if not slotInfo then return end
		
		if not deleteConfirmPending then
			deleteConfirmPending = true
			setButtonText(deleteBtn, "Confirm?")
			status.Text = "Click again to delete Slot " .. selectedSlot
			status.TextColor3 = COLORS.textWarning
			
			task.delay(3, function()
				if deleteConfirmPending then
					deleteConfirmPending = false
					setButtonText(deleteBtn, "Delete")
					status.Text = "Select a slot to save or load"
					status.TextColor3 = COLORS.textDim
				end
			end)
		else
			deleteConfirmPending = false
			isProcessing = true
			setButtonText(deleteBtn, "Deleting...")
			status.Text = "Deleting Slot " .. selectedSlot .. "..."
			status.TextColor3 = COLORS.textDim
			
			DeleteSlot:FireServer(selectedSlot)
		end
	end)
	
	-- Purchase with Robux
	if purchaseRobuxBtn then
		purchaseRobuxBtn.MouseButton1Click:Connect(function()
			if isProcessing then return end
			
			isProcessing = true
			setButtonText(purchaseRobuxBtn, "Processing...")
			status.Text = "Opening purchase..."
			status.TextColor3 = COLORS.textDim
			
			PurchaseSlot:FireServer()
			
			task.delay(5, function()
				if isProcessing then
					isProcessing = false
					local robuxText = IsMobile and ("Buy (" .. ROBUX_ICON .. SLOT_PRICE_ROBUX .. ")") or (ROBUX_ICON .. SLOT_PRICE_ROBUX .. " Robux")
					setButtonText(purchaseRobuxBtn, robuxText)
					status.Text = "Select a slot to save or load"
					status.TextColor3 = COLORS.textDim
				end
			end)
		end)
	end
	
	-- Purchase with Coins
	if purchaseCoinsBtn then
		purchaseCoinsBtn.MouseButton1Click:Connect(function()
			if isProcessing then return end
			
			isProcessing = true
			setButtonText(purchaseCoinsBtn, "Processing...")
			status.Text = "Purchasing with coins..."
			status.TextColor3 = COLORS.textDim
			
			PurchaseSlotWithCoins:FireServer()
			
			task.delay(5, function()
				if isProcessing then
					isProcessing = false
					setButtonText(purchaseCoinsBtn, SLOT_PRICE_COINS .. " Coins")
					status.Text = "Select a slot to save or load"
					status.TextColor3 = COLORS.textDim
				end
			end)
		end)
	end
	
	-- Close
	closeBtn.MouseButton1Click:Connect(function()
		if isProcessing then return end
		closeUI()
	end)
	
	-- Close on overlay click
	ui.Overlay.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not isProcessing then
			closeUI()
		end
	end)
	
	-- Close on Escape
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.KeyCode == Enum.KeyCode.Escape and not isProcessing then
			local uiCheck = playerGui:FindFirstChild("SaveLoadUI")
			if uiCheck and uiCheck.Enabled then
				closeUI()
			end
		end
	end)
end

-- ============================================
-- REFRESH SLOT DATA
-- ============================================
local function refreshSlotData()
	local ui = playerGui:FindFirstChild("SaveLoadUI")
	if not ui or not ui.Enabled then return end
	
	local success, data = pcall(function()
		return GetSlotInfo:InvokeServer()
	end)
	
	if success and data then
		populateSlots(ui, data)
	end
end

-- ============================================
-- NOTIFICATION TOAST (Minecraft-style)
-- ============================================
local function showNotificationToast(message, isSuccess)
	if isTitleScreenOpen() then
		pendingAutoloadMessage = { message = message, isSuccess = isSuccess }
		return
	end
	
	local existingNotif = playerGui:FindFirstChild("AutoLoadNotification")
	if existingNotif then existingNotif:Destroy() end
	
	local notifGui = Instance.new("ScreenGui")
	notifGui.Name = "AutoLoadNotification"
	notifGui.ResetOnSpawn = false
	notifGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	notifGui.ScreenInsets = Enum.ScreenInsets.None
	notifGui.Parent = playerGui
	
	local notifFrame = Instance.new("Frame")
	notifFrame.Name = "Notification"
	notifFrame.Size = UDim2.new(0, 380, 0, 50)
	notifFrame.Position = UDim2.new(0.5, 0, 0, -60)
	notifFrame.AnchorPoint = Vector2.new(0.5, 0)
	notifFrame.BackgroundColor3 = isSuccess and Color3.fromRGB(40, 70, 40) or Color3.fromRGB(80, 35, 35)
	notifFrame.BorderSizePixel = 0
	notifFrame.Parent = notifGui
	
	addMinecraftBorder(notifFrame,
		isSuccess and Color3.fromRGB(70, 120, 70) or Color3.fromRGB(130, 60, 60),
		isSuccess and Color3.fromRGB(20, 40, 20) or Color3.fromRGB(45, 18, 18),
		2
	)
	
	local icon = Instance.new("TextLabel")
	icon.Size = UDim2.new(0, 44, 1, 0)
	icon.Position = UDim2.new(0, 0, 0, 0)
	icon.BackgroundTransparency = 1
	icon.Text = isSuccess and "OK" or "!"
	icon.TextSize = 18
	icon.Font = FONT
	icon.TextColor3 = COLORS.text
	icon.Parent = notifFrame
	addTextShadow(icon, icon.Text, icon.TextSize, FONT, 1, 1)
	
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -50, 1, 0)
	label.Position = UDim2.new(0, 44, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = message
	label.TextSize = 13
	label.Font = FONT
	label.TextColor3 = COLORS.text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.Parent = notifFrame
	addTextShadow(label, message, label.TextSize, FONT, 1, 1)
	
	local tweenIn = TweenService:Create(notifFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, 6)
	})
	tweenIn:Play()
	
	task.delay(3, function()
		local tweenOut = TweenService:Create(notifFrame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 0, -60)
		})
		tweenOut:Play()
		tweenOut.Completed:Connect(function()
			notifGui:Destroy()
		end)
	end)
end

-- Check for pending notifications
task.spawn(function()
	while true do
		task.wait(0.5)
		if pendingAutoloadMessage and not isTitleScreenOpen() then
			local msg = pendingAutoloadMessage
			pendingAutoloadMessage = nil
			task.wait(0.5)
			showNotificationToast(msg.message, msg.isSuccess)
		end
	end
end)

-- ============================================
-- SAVE/LOAD RESULT HANDLER
-- ============================================
if SaveLoadResult then
	SaveLoadResult.OnClientEvent:Connect(function(action, success, message)
		print("[SaveLoadUI] Received result:", action, success, message)
		
		isProcessing = false
		
		if action == "autoload" then
			if success then
				showNotificationToast(message, true)
			end
			return
		end
		
		if action == "slotPurchased" then
			if success then
				showNotificationToast("New slot unlocked! You now have " .. message .. " slots.", true)
				refreshSlotData()
			else
				showNotificationToast(message, false)
			end
			
			-- Reset purchase button text
			local ui = playerGui:FindFirstChild("SaveLoadUI")
			if ui and ui.Enabled then
				local pnl = ui.Panel
				local bRow = pnl:FindFirstChild("ButtonRow")
				local pRow = pnl:FindFirstChild("PurchaseRow")
				local rBtn = (pRow and pRow:FindFirstChild("PurchaseRobux")) or (bRow and bRow:FindFirstChild("PurchaseRobux"))
				local cBtn = (pRow and pRow:FindFirstChild("PurchaseCoins")) or (bRow and bRow:FindFirstChild("PurchaseCoins"))
				if rBtn then
					local robuxText = IsMobile and ("Buy (" .. ROBUX_ICON .. SLOT_PRICE_ROBUX .. ")") or (ROBUX_ICON .. SLOT_PRICE_ROBUX .. " Robux")
					setButtonText(rBtn, robuxText)
				end
				if cBtn then
					setButtonText(cBtn, SLOT_PRICE_COINS .. " Coins")
				end
			end
			return
		end
		
		local ui = playerGui:FindFirstChild("SaveLoadUI")
		if not ui or not ui.Enabled then return end
		
		local panel = ui.Panel
		local buttonRow = panel.ButtonRow
		local saveBtn = buttonRow.SaveButton
		local loadBtn = buttonRow.LoadButton
		local deleteBtn = buttonRow.DeleteButton
		local purchaseRow = panel:FindFirstChild("PurchaseRow")
		local purchaseRobuxBtn = (purchaseRow and purchaseRow:FindFirstChild("PurchaseRobux")) or buttonRow:FindFirstChild("PurchaseRobux")
		local purchaseCoinsBtn = (purchaseRow and purchaseRow:FindFirstChild("PurchaseCoins")) or buttonRow:FindFirstChild("PurchaseCoins")
		local status = panel.Status
		
		setButtonText(saveBtn, "Save")
		setButtonText(loadBtn, "Load")
		setButtonText(deleteBtn, "Delete")
		local restoreBtn = buttonRow:FindFirstChild("RestoreAutoButton")
		if restoreBtn then
			setButtonText(restoreBtn, "Restore Auto")
		end
		if purchaseRobuxBtn then
			local robuxText = IsMobile and ("Buy (" .. ROBUX_ICON .. SLOT_PRICE_ROBUX .. ")") or (ROBUX_ICON .. SLOT_PRICE_ROBUX .. " Robux")
			setButtonText(purchaseRobuxBtn, robuxText)
		end
		if purchaseCoinsBtn then
			setButtonText(purchaseCoinsBtn, SLOT_PRICE_COINS .. " Coins")
		end
		
		if action == "save" then
			if success then
				status.Text = message
				status.TextColor3 = COLORS.textSuccess
				refreshSlotData()
			else
				status.Text = message
				status.TextColor3 = COLORS.textError
			end
		elseif action == "load" then
			if success then
				status.Text = message
				status.TextColor3 = COLORS.textSuccess
				task.delay(1.5, closeUI)
			else
				status.Text = message
				status.TextColor3 = COLORS.textError
			end
		elseif action == "delete" then
			if success then
				status.Text = message
				status.TextColor3 = COLORS.textSuccess
				refreshSlotData()
			else
				status.Text = message
				status.TextColor3 = COLORS.textError
			end
		elseif action == "rename" then
			if success then
				status.Text = "Renamed to '" .. message .. "'"
				status.TextColor3 = COLORS.textSuccess
				refreshSlotData()
			else
				status.Text = message
				status.TextColor3 = COLORS.textError
			end
		end
	end)
end

-- ============================================
-- OPEN UI HANDLER
-- ============================================
if OpenSaveLoadUI then
	OpenSaveLoadUI.OnClientEvent:Connect(function()
		isProcessing = false
		selectedSlot = nil
		
		local ui = createUI()
		
		local success, data = pcall(function()
			return GetSlotInfo:InvokeServer()
		end)
		
		if success and data then
			setupButtons(ui, data.activeSlot or 1)
			populateSlots(ui, data)
		else
			setupButtons(ui, 1)
			local status = ui.Panel.Status
			status.Text = "Failed to load save data"
			status.TextColor3 = COLORS.textError
		end
		
		ui.Enabled = true
		unlockMouse()
		
		-- Add blur effect
		if saveLoadBlur then saveLoadBlur:Destroy() end
		saveLoadBlur = Instance.new("BlurEffect")
		saveLoadBlur.Name = "SaveLoadBlur"
		saveLoadBlur.Size = 0
		saveLoadBlur.Parent = Lighting
		TweenService:Create(saveLoadBlur, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = 20
		}):Play()
	end)
end

print("[SaveLoadUI] Minecraft-style multi-slot system initialized")
