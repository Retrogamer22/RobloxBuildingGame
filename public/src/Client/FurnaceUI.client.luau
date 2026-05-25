--[[
	FurnaceUI
	Minecraft-style furnace UI with embedded personal inventory + hotbar
	Matches ChestUI / CraftingTableUI layout and styling.
	- Opens when player interacts with a placed furnace
	- Input slot (top), flame, fuel slot (bottom) + arrow + output slot (no real smelting yet)
	- Personal inventory grid + hotbar row embedded in the panel
	- Side-by-side layout on mobile (furnace left, personal+hotbar right)
	- Stacked layout on desktop (furnace top, personal+hotbar below)
	- On-screen hotbar hidden while open
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local BlockPresetsModule = ReplicatedStorage:WaitForChild("BlockPresets", 10)
local BlockPresets = BlockPresetsModule and require(BlockPresetsModule)

-- ============================================
-- STATE
-- ============================================
local isOpen = false
local currentBlock = nil
local screenGui = nil
local mainFrame = nil

-- Furnace slot frames (not yet interactive; smelting TBD)
local inputSlotFrame = nil
local fuelSlotFrame = nil
local outputSlotFrame = nil

-- Personal inventory + hotbar slot frames (interactive, sync with InventoryController)
local personalSlotFrames = {}
local hotbarSlotFrames = {}

-- ============================================
-- DARK MODE COLOR THEME
-- ============================================
local BEVEL_SIZE = 3
local FONT = Enum.Font.Arcade

local Colors = {
	Background = Color3.fromRGB(30, 30, 30),
	Surface = Color3.fromRGB(40, 40, 40),
	Text = Color3.fromRGB(220, 220, 220),
	TextMuted = Color3.fromRGB(140, 140, 140),
	Border = Color3.fromRGB(10, 10, 10),
	BorderHighlight = Color3.fromRGB(70, 70, 70),
	CellBg = Color3.fromRGB(50, 50, 50),
	CellHover = Color3.fromRGB(70, 70, 90),
	Success = Color3.fromRGB(53, 180, 53),
	Danger = Color3.fromRGB(220, 53, 53),
	ArrowColor = Color3.fromRGB(100, 100, 100),
	FlameInactive = Color3.fromRGB(70, 70, 70),
}

local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local SideBySide = IsMobile

local SLOT_PADDING = IsMobile and 2 or 3
local PERSONAL_COLS = 9
local HOTBAR_COLS = 10

-- Furnace content width math (side-by-side panel):
--   leftContent = SLOT_SIZE + 18 + 40 + 18 + (SLOT_SIZE + 8) = 2*S + 84
--   rightContent (personal inv) = 9*S + 8*P
--   panelW = 16 + (2S + 84 + 12) + 16 + (9S + 8P + 12) + 16 = 156 + 11*S + 8*P
local function computeSlotSize()
	if not IsMobile then return 48 end
	local cam = workspace.CurrentCamera
	local screenW = (cam and cam.ViewportSize.X) or 800
	if screenW < 100 then screenW = 800 end
	if SideBySide then
		local maxS = math.floor((screenW - 156 - 8 * SLOT_PADDING) / 11)
		return math.clamp(maxS, 28, 42)
	else
		return 38
	end
end

local SLOT_SIZE = computeSlotSize()

-- ============================================
-- BEVEL HELPERS
-- ============================================
local function addBevel(frame, highlightColor, shadowColor)
	local hl = highlightColor or Color3.fromRGB(80, 80, 80)
	local sh = shadowColor or Color3.fromRGB(0, 0, 0)
	local hlAlpha = 0.3
	local shAlpha = 0.3

	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = hl
	top.BackgroundTransparency = hlAlpha
	top.BorderSizePixel = 0
	top.ZIndex = 5
	top.Parent = frame

	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = hl
	left.BackgroundTransparency = hlAlpha
	left.BorderSizePixel = 0
	left.ZIndex = 5
	left.Parent = frame

	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL_SIZE)
	bottom.BackgroundColor3 = sh
	bottom.BackgroundTransparency = shAlpha
	bottom.BorderSizePixel = 0
	bottom.ZIndex = 5
	bottom.Parent = frame

	local right = Instance.new("Frame")
	right.Name = "BevelRight"
	right.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	right.Position = UDim2.new(1, -BEVEL_SIZE, 0, 0)
	right.BackgroundColor3 = sh
	right.BackgroundTransparency = shAlpha
	right.BorderSizePixel = 0
	right.ZIndex = 5
	right.Parent = frame
end

local function addInsetBevel(frame, shadowColor, highlightColor)
	local sh = shadowColor or Color3.fromRGB(10, 10, 10)
	local hl = highlightColor or Color3.fromRGB(70, 70, 70)

	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = sh
	top.BackgroundTransparency = 0
	top.BorderSizePixel = 0
	top.ZIndex = 5
	top.Parent = frame

	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = sh
	left.BackgroundTransparency = 0
	left.BorderSizePixel = 0
	left.ZIndex = 5
	left.Parent = frame

	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL_SIZE)
	bottom.BackgroundColor3 = hl
	bottom.BackgroundTransparency = 0
	bottom.BorderSizePixel = 0
	bottom.ZIndex = 5
	bottom.Parent = frame

	local right = Instance.new("Frame")
	right.Name = "BevelRight"
	right.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	right.Position = UDim2.new(1, -BEVEL_SIZE, 0, 0)
	right.BackgroundColor3 = hl
	right.BackgroundTransparency = 0
	right.BorderSizePixel = 0
	right.ZIndex = 5
	right.Parent = frame
end

-- ============================================
-- INVENTORY CONTROLLER ACCESS
-- ============================================
local function getInvController()
	return _G.InventoryController
end

-- ============================================
-- PERSONAL INVENTORY SLOT HELPERS
-- ============================================
local function updatePersonalSlotViewport(slotIndex)
	local slotFrame = personalSlotFrames[slotIndex]
	if not slotFrame then return end
	
	local oldViewport = slotFrame:FindFirstChild("Viewport")
	if oldViewport then oldViewport:Destroy() end
	
	local countLabel = slotFrame:FindFirstChild("CountLabel")
	
	local inv = getInvController()
	if not inv then return end
	local survSlots = inv.GetSurvivalSlots and inv.GetSurvivalSlots() or {}
	local data = survSlots[slotIndex]
	
	if not data or not data.p then
		if countLabel then countLabel.Visible = false end
		return
	end
	
	if countLabel then
		if data.n and data.n > 1 then
			countLabel.Text = tostring(data.n)
			countLabel.Visible = true
		else
			countLabel.Visible = false
		end
	end
	
	local preset = BlockPresets.GetPreset(data.p)
	if not preset or not inv.CreateViewportPreview or not inv.SetupViewportModel then return end
	
	local color = nil
	if data.c and type(data.c) == "table" then
		color = Color3.fromRGB(data.c[1] or 255, data.c[2] or 255, data.c[3] or 255)
	elseif preset.Color then
		color = preset.Color
	end
	
	local viewport = inv.CreateViewportPreview(slotFrame, UDim2.new(1, -6, 1, -6))
	viewport.Position = UDim2.new(0, 3, 0, 3)
	viewport.ZIndex = 4
	
	local shape = BlockPresets.GetShape(preset.Shape)
	if shape then
		inv.SetupViewportModel(
			viewport, shape.TemplateName, color,
			preset.Material, preset.MaterialVariant,
			preset.UseBlockModel, preset.BlockModelName,
			preset.IsDecoration, preset.DecorationName,
			preset.BlockModelFolder, preset.ApplyColor, preset.LeatherTint
		)
	end
end

local function renderAllPersonalSlots()
	local inv = getInvController()
	if not inv then return end
	local slotCount = inv.GetSurvivalSlotCount and inv.GetSurvivalSlotCount() or 45
	for i = 1, slotCount do
		updatePersonalSlotViewport(i)
	end
end

local function onPersonalSlotClick(slotIndex)
	local inv = getInvController()
	if not inv then return end
	
	local survSlots = inv.GetSurvivalSlots()
	local existingItem = survSlots[slotIndex]
	local isHolding = inv.IsHolding and inv.IsHolding()
	
	if isHolding then
		local heldItem = inv.GetHeldItem()
		if not heldItem then return end
		
		local colorArray = nil
		if heldItem.Color then
			colorArray = {
				math.floor(heldItem.Color.R * 255 + 0.5),
				math.floor(heldItem.Color.G * 255 + 0.5),
				math.floor(heldItem.Color.B * 255 + 0.5),
			}
		end
		local newItem = { p = heldItem.PresetId, c = colorArray, n = heldItem.Count or 1 }
		
		if existingItem and existingItem.p then
			inv.SetSurvivalSlot(slotIndex, newItem)
			updatePersonalSlotViewport(slotIndex)
			
			local existColor = nil
			if existingItem.c and type(existingItem.c) == "table" then
				existColor = Color3.fromRGB(existingItem.c[1] or 255, existingItem.c[2] or 255, existingItem.c[3] or 255)
			else
				local existPreset = BlockPresets.GetPreset(existingItem.p)
				if existPreset then existColor = existPreset.Color end
			end
			
			inv.DiscardHeld()
			inv.PickUpItem(existingItem.p, existColor, nil, existingItem.n or 1)
		else
			inv.SetSurvivalSlot(slotIndex, newItem)
			updatePersonalSlotViewport(slotIndex)
			inv.DiscardHeld()
		end
		
		local sf = personalSlotFrames[slotIndex]
		if sf then
			local orig = sf.BackgroundColor3
			sf.BackgroundColor3 = Colors.Success
			task.delay(0.15, function()
				TweenService:Create(sf, TweenInfo.new(0.2), {BackgroundColor3 = orig}):Play()
			end)
		end
	else
		if existingItem and existingItem.p then
			local color = nil
			if existingItem.c and type(existingItem.c) == "table" then
				color = Color3.fromRGB(existingItem.c[1] or 255, existingItem.c[2] or 255, existingItem.c[3] or 255)
			else
				local preset = BlockPresets.GetPreset(existingItem.p)
				if preset then color = preset.Color end
			end
			
			inv.SetSurvivalSlot(slotIndex, nil)
			updatePersonalSlotViewport(slotIndex)
			inv.PickUpItem(existingItem.p, color, nil, existingItem.n or 1)
		end
	end
end

-- ============================================
-- HOTBAR SLOT HELPERS
-- ============================================
local function updateHotbarSlotViewport(slotIndex)
	local slotFrame = hotbarSlotFrames[slotIndex]
	if not slotFrame then return end
	
	local oldViewport = slotFrame:FindFirstChild("Viewport")
	if oldViewport then oldViewport:Destroy() end
	
	local countLabel = slotFrame:FindFirstChild("CountLabel")
	
	local inv = getInvController()
	if not inv or not inv.GetHotbarSlot then
		if countLabel then countLabel.Visible = false end
		return
	end
	
	local data = inv.GetHotbarSlot(slotIndex)
	if not data or data.isTool or not data.p then
		if countLabel then countLabel.Visible = false end
		return
	end
	
	if countLabel then
		if data.n and data.n > 1 then
			countLabel.Text = tostring(data.n)
			countLabel.Visible = true
		else
			countLabel.Visible = false
		end
	end
	
	local preset = BlockPresets.GetPreset(data.p)
	if not preset or not inv.CreateViewportPreview or not inv.SetupViewportModel then return end
	
	local color = nil
	if data.c and type(data.c) == "table" then
		color = Color3.fromRGB(data.c[1] or 255, data.c[2] or 255, data.c[3] or 255)
	elseif preset.Color then
		color = preset.Color
	end
	
	local viewport = inv.CreateViewportPreview(slotFrame, UDim2.new(1, -6, 1, -6))
	viewport.Position = UDim2.new(0, 3, 0, 3)
	viewport.ZIndex = 4
	
	local shape = BlockPresets.GetShape(preset.Shape)
	if shape then
		inv.SetupViewportModel(
			viewport, shape.TemplateName, color,
			preset.Material, preset.MaterialVariant,
			preset.UseBlockModel, preset.BlockModelName,
			preset.IsDecoration, preset.DecorationName,
			preset.BlockModelFolder, preset.ApplyColor, preset.LeatherTint
		)
	end
end

local function renderAllHotbarSlots()
	local inv = getInvController()
	if not inv or not inv.GetHotbarSize then return end
	local slotCount = inv.GetHotbarSize()
	for i = 1, slotCount do
		updateHotbarSlotViewport(i)
	end
end

local function onHotbarSlotClick(slotIndex)
	local inv = getInvController()
	if not inv or not inv.GetHotbarSlot then return end
	
	local existingItem = inv.GetHotbarSlot(slotIndex)
	local isHolding = inv.IsHolding and inv.IsHolding()
	
	if isHolding then
		local heldItem = inv.GetHeldItem()
		if not heldItem then return end
		
		local colorArray = nil
		if heldItem.Color then
			colorArray = {
				math.floor(heldItem.Color.R * 255 + 0.5),
				math.floor(heldItem.Color.G * 255 + 0.5),
				math.floor(heldItem.Color.B * 255 + 0.5),
			}
		end
		local newItem = { p = heldItem.PresetId, c = colorArray, n = heldItem.Count or 1 }
		
		if existingItem and existingItem.isTool then return end
		
		if existingItem and existingItem.p then
			inv.SetHotbarSlot(slotIndex, newItem)
			updateHotbarSlotViewport(slotIndex)
			
			local existColor = nil
			if existingItem.c and type(existingItem.c) == "table" then
				existColor = Color3.fromRGB(existingItem.c[1] or 255, existingItem.c[2] or 255, existingItem.c[3] or 255)
			else
				local existPreset = BlockPresets.GetPreset(existingItem.p)
				if existPreset then existColor = existPreset.Color end
			end
			
			inv.DiscardHeld()
			inv.PickUpItem(existingItem.p, existColor, nil, existingItem.n or 1)
		else
			inv.SetHotbarSlot(slotIndex, newItem)
			updateHotbarSlotViewport(slotIndex)
			inv.DiscardHeld()
		end
		
		local sf = hotbarSlotFrames[slotIndex]
		if sf then
			local orig = sf.BackgroundColor3
			sf.BackgroundColor3 = Colors.Success
			task.delay(0.15, function()
				TweenService:Create(sf, TweenInfo.new(0.2), {BackgroundColor3 = orig}):Play()
			end)
		end
	else
		if existingItem and existingItem.p and not existingItem.isTool then
			local color = nil
			if existingItem.c and type(existingItem.c) == "table" then
				color = Color3.fromRGB(existingItem.c[1] or 255, existingItem.c[2] or 255, existingItem.c[3] or 255)
			else
				local preset = BlockPresets.GetPreset(existingItem.p)
				if preset then color = preset.Color end
			end
			
			inv.SetHotbarSlot(slotIndex, nil)
			updateHotbarSlotViewport(slotIndex)
			inv.PickUpItem(existingItem.p, color, nil, existingItem.n or 1)
		end
	end
end

-- ============================================
-- GENERIC INTERACTIVE SLOT BUILDER
-- ============================================
local function createInteractiveSlot(parent, slotW, slotH, x, y, slotIndex, kind, isMobile)
	local slot = Instance.new("TextButton")
	slot.Name = kind .. "Slot_" .. slotIndex
	slot.Size = UDim2.new(0, slotW, 0, slotH)
	slot.Position = UDim2.new(0, x, 0, y)
	slot.BackgroundColor3 = Colors.CellBg
	slot.BorderSizePixel = 0
	slot.Text = ""
	slot.AutoButtonColor = false
	slot.ZIndex = 3
	slot.Parent = parent
	addInsetBevel(slot)
	
	local countLabel = Instance.new("TextLabel")
	countLabel.Name = "CountLabel"
	countLabel.Size = UDim2.new(0, 24, 0, 16)
	countLabel.Position = UDim2.new(1, -26, 1, -18)
	countLabel.BackgroundTransparency = 1
	countLabel.Text = ""
	countLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	countLabel.TextSize = 13
	countLabel.Font = Enum.Font.GothamBold
	countLabel.TextXAlignment = Enum.TextXAlignment.Right
	countLabel.ZIndex = 6
	countLabel.Visible = false
	countLabel.Parent = slot
	
	local countStroke = Instance.new("UIStroke")
	countStroke.Color = Color3.fromRGB(30, 30, 30)
	countStroke.Thickness = 1.5
	countStroke.Parent = countLabel
	
	slot.MouseEnter:Connect(function() slot.BackgroundColor3 = Colors.CellHover end)
	slot.MouseLeave:Connect(function() slot.BackgroundColor3 = Colors.CellBg end)
	
	local function getItem()
		if kind == "Personal" then
			local inv = getInvController()
			local survSlots = inv and inv.GetSurvivalSlots() or {}
			return survSlots[slotIndex]
		else
			local inv = getInvController()
			return inv and inv.GetHotbarSlot and inv.GetHotbarSlot(slotIndex)
		end
	end
	
	local function onClick()
		if kind == "Personal" then onPersonalSlotClick(slotIndex)
		else onHotbarSlotClick(slotIndex) end
	end
	
	local pressStart, longFired = nil, false
	
	slot.MouseButton1Down:Connect(function()
		pressStart = tick(); longFired = false
		if isMobile and not (getInvController() and getInvController().IsHolding()) then
			local st = pressStart
			task.delay(0.35, function()
				if pressStart == st and not longFired and isOpen then
					longFired = true
					local item = getItem()
					if item and item.p and not item.isTool then
						onClick()
					end
				end
			end)
		end
	end)
	slot.MouseButton1Up:Connect(function() pressStart = nil end)
	
	slot.MouseButton1Click:Connect(function()
		if longFired then return end
		local inv = getInvController()
		if isMobile and inv and not inv.IsHolding() then return end
		onClick()
	end)
	
	slot.MouseButton2Click:Connect(function()
		local inv = getInvController()
		if not inv then return end
		if kind == "Personal" then
			inv.SetSurvivalSlot(slotIndex, nil)
			updatePersonalSlotViewport(slotIndex)
		else
			local item = inv.GetHotbarSlot(slotIndex)
			if item and not item.isTool then
				inv.SetHotbarSlot(slotIndex, nil)
				updateHotbarSlotViewport(slotIndex)
			end
		end
	end)
	
	return slot
end

-- ============================================
-- FURNACE SLOT (visual only, smelting TBD)
-- ============================================
local function createFurnaceSlot(parent, x, y, size)
	local slot = Instance.new("TextButton")
	slot.Name = "FurnaceSlot"
	slot.Size = UDim2.new(0, size, 0, size)
	slot.Position = UDim2.new(0, x, 0, y)
	slot.BackgroundColor3 = Colors.CellBg
	slot.BorderSizePixel = 0
	slot.Text = ""
	slot.AutoButtonColor = false
	slot.ZIndex = 3
	slot.Parent = parent
	addInsetBevel(slot)
	
	slot.MouseEnter:Connect(function() slot.BackgroundColor3 = Colors.CellHover end)
	slot.MouseLeave:Connect(function() slot.BackgroundColor3 = Colors.CellBg end)
	
	return slot
end

-- ============================================
-- BUILD UI (one-time: ScreenGui + overlay only)
-- ============================================
local function buildUI()
	if screenGui then screenGui:Destroy() end

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "FurnaceUI"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 15
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	local overlay = Instance.new("TextButton")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Text = ""
	overlay.ZIndex = 1
	overlay.Parent = screenGui

	overlay.MouseButton1Click:Connect(function()
		if isOpen then _G.FurnaceUI.Close() end
	end)

	mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainPanel"
	mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	mainFrame.Position = UDim2.new(0.5, 0, 0.45, 0)
	mainFrame.BackgroundColor3 = Colors.Background
	mainFrame.BorderSizePixel = 0
	mainFrame.ZIndex = 2
	mainFrame.Parent = screenGui

	addBevel(mainFrame)
end

-- ============================================
-- POPULATE UI (rebuilt on each open so slot size adapts to viewport)
-- ============================================
local function populateUI()
	for _, child in mainFrame:GetChildren() do
		if not child.Name:match("^Bevel") then
			child:Destroy()
		end
	end
	personalSlotFrames = {}
	hotbarSlotFrames = {}
	inputSlotFrame = nil
	fuelSlotFrame = nil
	outputSlotFrame = nil
	
	SLOT_SIZE = computeSlotSize()
	mainFrame.BackgroundColor3 = Colors.Background
	
	local panelPadding = 16
	local titleHeight = 32
	local closeBtnSize = 28
	local separatorGap = 8
	local invLabelHeight = 24
	
	-- Furnace content layout:
	--   [Input]   ==>   [Output]
	--    flame
	--   [Fuel]
	local verticalGap = 10
	local flameSize = 20
	local arrowWidth = 40
	local arrowPadding = 18
	local outputSize = SLOT_SIZE + 8
	
	local leftColWidth = SLOT_SIZE
	local leftColHeight = SLOT_SIZE + verticalGap + flameSize + verticalGap + SLOT_SIZE
	local furnaceContentWidth = leftColWidth + arrowPadding + arrowWidth + arrowPadding + outputSize
	local furnaceContentHeight = leftColHeight
	
	-- Personal inventory
	local inv = getInvController()
	local personalRows = inv and inv.GetSurvivalRows and inv.GetSurvivalRows() or 5
	local personalSlotCount = inv and inv.GetSurvivalSlotCount and inv.GetSurvivalSlotCount() or 45
	local personalGridWidth = PERSONAL_COLS * (SLOT_SIZE + SLOT_PADDING) - SLOT_PADDING
	local personalGridHeight = personalRows * (SLOT_SIZE + SLOT_PADDING) - SLOT_PADDING
	
	local hotbarSlotW = math.max(20, math.floor((personalGridWidth - (HOTBAR_COLS - 1) * SLOT_PADDING) / HOTBAR_COLS))
	local hotbarRowHeight = SLOT_SIZE
	local hotbarGap = 8
	local hotbarContainerHeight = hotbarRowHeight + 12
	
	local panelWidth, panelHeight
	if SideBySide then
		local gridGap = 16
		local leftColumnHeight = furnaceContentHeight + 12
		local rightColumnHeight = (personalGridHeight + 12) + hotbarGap + hotbarContainerHeight
		local maxColHeight = math.max(leftColumnHeight, rightColumnHeight)
		panelWidth = panelPadding * 2 + (furnaceContentWidth + 12) + gridGap + (personalGridWidth + 12)
		panelHeight = titleHeight + 6 + maxColHeight + panelPadding
	else
		panelWidth = math.max(furnaceContentWidth, personalGridWidth) + panelPadding * 2
		panelHeight = titleHeight + 6 + (furnaceContentHeight + 12) + separatorGap + invLabelHeight
			+ (personalGridHeight + 12) + hotbarGap + hotbarContainerHeight + panelPadding
	end
	mainFrame.Size = UDim2.new(0, panelWidth, 0, panelHeight)
	
	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -panelPadding * 2 - closeBtnSize - 8, 0, titleHeight)
	title.Position = UDim2.new(0, panelPadding, 0, 6)
	title.BackgroundTransparency = 1
	title.Text = "Furnace"
	title.TextColor3 = Colors.Text
	title.TextSize = 16
	title.Font = FONT
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 3
	title.Parent = mainFrame
	
	-- Close button
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseBtn"
	closeBtn.Size = UDim2.new(0, closeBtnSize, 0, closeBtnSize)
	closeBtn.Position = UDim2.new(1, -panelPadding - closeBtnSize, 0, 6)
	closeBtn.BackgroundColor3 = Colors.Danger
	closeBtn.BorderSizePixel = 0
	closeBtn.Text = "X"
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.TextSize = 16
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.ZIndex = 10
	closeBtn.Parent = mainFrame
	addBevel(closeBtn, Color3.fromRGB(255, 130, 130), Color3.fromRGB(110, 20, 20))
	closeBtn.MouseButton1Click:Connect(function()
		if isOpen then _G.FurnaceUI.Close() end
	end)
	
	-- ======== FURNACE CONTENT ========
	local furnaceContainerY = titleHeight + 6
	
	local furnaceContainer = Instance.new("Frame")
	furnaceContainer.Name = "FurnaceContainer"
	furnaceContainer.Size = UDim2.new(0, furnaceContentWidth + 12, 0, furnaceContentHeight + 12)
	furnaceContainer.Position = UDim2.new(0, panelPadding - 6, 0, furnaceContainerY)
	furnaceContainer.BackgroundColor3 = Colors.Background
	furnaceContainer.BorderSizePixel = 0
	furnaceContainer.ZIndex = 2
	furnaceContainer.Parent = mainFrame
	addInsetBevel(furnaceContainer)
	
	local furnaceContent = Instance.new("Frame")
	furnaceContent.Name = "FurnaceContent"
	furnaceContent.Size = UDim2.new(0, furnaceContentWidth, 0, furnaceContentHeight)
	furnaceContent.Position = UDim2.new(0, 6, 0, 6)
	furnaceContent.BackgroundTransparency = 1
	furnaceContent.ZIndex = 3
	furnaceContent.Parent = furnaceContainer
	
	-- Input slot (top of left column)
	inputSlotFrame = createFurnaceSlot(furnaceContent, 0, 0, SLOT_SIZE)
	inputSlotFrame.Name = "InputSlot"
	
	-- Flame indicator (centered below input slot)
	local flameX = (SLOT_SIZE - flameSize) / 2
	local flameY = SLOT_SIZE + verticalGap
	local flame = Instance.new("TextLabel")
	flame.Name = "FlameIcon"
	flame.Size = UDim2.new(0, flameSize, 0, flameSize)
	flame.Position = UDim2.new(0, flameX, 0, flameY)
	flame.BackgroundTransparency = 1
	flame.Text = "^"
	flame.TextSize = 20
	flame.Font = FONT
	flame.TextColor3 = Colors.FlameInactive
	flame.ZIndex = 3
	flame.Parent = furnaceContent
	
	-- Fuel slot (below flame)
	local fuelY = SLOT_SIZE + verticalGap + flameSize + verticalGap
	fuelSlotFrame = createFurnaceSlot(furnaceContent, 0, fuelY, SLOT_SIZE)
	fuelSlotFrame.Name = "FuelSlot"
	
	-- Arrow (centered vertically)
	local arrowX = leftColWidth + arrowPadding
	local arrowY = (furnaceContentHeight - 20) / 2
	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.Size = UDim2.new(0, arrowWidth, 0, 20)
	arrow.Position = UDim2.new(0, arrowX, 0, arrowY)
	arrow.BackgroundTransparency = 1
	arrow.Text = "==>"
	arrow.TextColor3 = Colors.ArrowColor
	arrow.TextSize = 18
	arrow.Font = FONT
	arrow.TextXAlignment = Enum.TextXAlignment.Center
	arrow.ZIndex = 3
	arrow.Parent = furnaceContent
	
	-- Output slot (larger, vertically centered)
	local outputX = leftColWidth + arrowPadding + arrowWidth + arrowPadding
	local outputY = (furnaceContentHeight - outputSize) / 2
	outputSlotFrame = createFurnaceSlot(furnaceContent, outputX, outputY, outputSize)
	outputSlotFrame.Name = "OutputSlot"
	
	-- ======== PERSONAL INVENTORY + HOTBAR ========
	local personalContainerX, personalContainerY
	
	if SideBySide then
		personalContainerX = panelPadding - 6 + (furnaceContentWidth + 12) + 16
		personalContainerY = furnaceContainerY
	else
		local separatorY = furnaceContainerY + furnaceContentHeight + 12 + separatorGap
		
		local sepLine = Instance.new("Frame")
		sepLine.Name = "Separator"
		sepLine.Size = UDim2.new(0, personalGridWidth, 0, 1)
		sepLine.Position = UDim2.new(0.5, -personalGridWidth/2, 0, separatorY - 4)
		sepLine.BackgroundColor3 = Colors.BorderHighlight
		sepLine.BackgroundTransparency = 0.5
		sepLine.BorderSizePixel = 0
		sepLine.ZIndex = 3
		sepLine.Parent = mainFrame
		
		local invLabel = Instance.new("TextLabel")
		invLabel.Name = "InventoryLabel"
		invLabel.Size = UDim2.new(0, personalGridWidth, 0, invLabelHeight)
		invLabel.Position = UDim2.new(0.5, -personalGridWidth/2, 0, separatorY)
		invLabel.BackgroundTransparency = 1
		invLabel.Text = "Inventory"
		invLabel.TextColor3 = Colors.Text
		invLabel.TextSize = 14
		invLabel.Font = FONT
		invLabel.TextXAlignment = Enum.TextXAlignment.Left
		invLabel.ZIndex = 3
		invLabel.Parent = mainFrame
		
		personalContainerX = (panelWidth - (personalGridWidth + 12)) / 2
		personalContainerY = separatorY + invLabelHeight
	end
	
	local personalContainer = Instance.new("Frame")
	personalContainer.Name = "PersonalContainer"
	personalContainer.Size = UDim2.new(0, personalGridWidth + 12, 0, personalGridHeight + 12)
	personalContainer.Position = UDim2.new(0, personalContainerX, 0, personalContainerY)
	personalContainer.BackgroundColor3 = Colors.Background
	personalContainer.BorderSizePixel = 0
	personalContainer.ZIndex = 2
	personalContainer.Parent = mainFrame
	addInsetBevel(personalContainer)
	
	local personalSlotContainer = Instance.new("Frame")
	personalSlotContainer.Name = "PersonalSlots"
	personalSlotContainer.Size = UDim2.new(0, personalGridWidth, 0, personalGridHeight)
	personalSlotContainer.Position = UDim2.new(0, 6, 0, 6)
	personalSlotContainer.BackgroundTransparency = 1
	personalSlotContainer.ZIndex = 3
	personalSlotContainer.Parent = personalContainer
	
	for row = 0, personalRows - 1 do
		for col = 0, PERSONAL_COLS - 1 do
			local slotIndex = row * PERSONAL_COLS + col + 1
			local x = col * (SLOT_SIZE + SLOT_PADDING)
			local y = row * (SLOT_SIZE + SLOT_PADDING)
			local pSlot = createInteractiveSlot(personalSlotContainer, SLOT_SIZE, SLOT_SIZE, x, y, slotIndex, "Personal", IsMobile)
			personalSlotFrames[slotIndex] = pSlot
		end
	end
	
	-- Hotbar row below personal inventory
	local hotbarContainerY = personalContainerY + personalGridHeight + 12 + hotbarGap
	
	local hotbarContainer = Instance.new("Frame")
	hotbarContainer.Name = "HotbarContainer"
	hotbarContainer.Size = UDim2.new(0, personalGridWidth + 12, 0, hotbarContainerHeight)
	hotbarContainer.Position = UDim2.new(0, personalContainerX, 0, hotbarContainerY)
	hotbarContainer.BackgroundColor3 = Colors.Background
	hotbarContainer.BorderSizePixel = 0
	hotbarContainer.ZIndex = 2
	hotbarContainer.Parent = mainFrame
	addInsetBevel(hotbarContainer)
	
	local hotbarSlotContainer = Instance.new("Frame")
	hotbarSlotContainer.Name = "HotbarSlots"
	hotbarSlotContainer.Size = UDim2.new(0, personalGridWidth, 0, hotbarRowHeight)
	hotbarSlotContainer.Position = UDim2.new(0, 6, 0, 6)
	hotbarSlotContainer.BackgroundTransparency = 1
	hotbarSlotContainer.ZIndex = 3
	hotbarSlotContainer.Parent = hotbarContainer
	
	for col = 0, HOTBAR_COLS - 1 do
		local slotIndex = col + 1
		local x = col * (hotbarSlotW + SLOT_PADDING)
		local hSlot = createInteractiveSlot(hotbarSlotContainer, hotbarSlotW, hotbarRowHeight, x, 0, slotIndex, "Hotbar", IsMobile)
		
		if not IsMobile then
			local numLabel = Instance.new("TextLabel")
			numLabel.Name = "NumLabel"
			numLabel.Size = UDim2.new(0, 14, 0, 14)
			numLabel.Position = UDim2.new(0, 3, 0, 2)
			numLabel.BackgroundTransparency = 1
			numLabel.Text = (slotIndex == 10) and "0" or tostring(slotIndex)
			numLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
			numLabel.TextSize = 10
			numLabel.Font = FONT
			numLabel.ZIndex = 6
			numLabel.Parent = hSlot
		end
		
		hotbarSlotFrames[slotIndex] = hSlot
	end
end

-- ============================================
-- OPEN / CLOSE
-- ============================================
local function openUI(block)
	if isOpen then return end
	isOpen = true
	currentBlock = block

	populateUI()
	screenGui.Enabled = true

	local blur = Lighting:FindFirstChild("FurnaceUIBlur")
	if not blur then
		blur = Instance.new("BlurEffect")
		blur.Name = "FurnaceUIBlur"
		blur.Parent = Lighting
	end
	blur.Size = 12
	
	local inv = getInvController()
	if inv then
		if inv.IsSurvivalLoaded and inv.IsSurvivalLoaded() then
			renderAllPersonalSlots()
		else
			if inv.RequestSurvivalData then inv.RequestSurvivalData() end
		end
		renderAllHotbarSlots()
		if inv.SetHotbarVisible then inv.SetHotbarVisible(false) end
	end
end

local function closeUI()
	if not isOpen then return end
	isOpen = false
	currentBlock = nil
	
	local inv = getInvController()
	if inv and inv.IsHolding and inv.IsHolding() then
		if inv.CancelHeldItem then inv.CancelHeldItem() end
	end
	
	screenGui.Enabled = false

	local blur = Lighting:FindFirstChild("FurnaceUIBlur")
	if blur then
		blur.Size = 0
	end
	
	if inv and inv.SetHotbarVisible then inv.SetHotbarVisible(true) end

	if _G.BlockInteractionController and _G.BlockInteractionController.NotifyClosed then
		_G.BlockInteractionController.NotifyClosed()
	end
end

-- ============================================
-- INPUT
-- ============================================
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not isOpen then return end
	if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.E then
		closeUI()
	end
end)

RunService.RenderStepped:Connect(function()
	if isOpen then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end)

-- ============================================
-- INIT
-- ============================================
buildUI()

_G.FurnaceUI = {
	IsOpen = function() return isOpen end,
	Open = function(block) openUI(block) end,
	Close = function() closeUI() end,
	GetCurrentBlock = function() return currentBlock end,
}

-- Refresh personal slots when survival data loads
task.defer(function()
	local attempts = 0
	while not _G.InventoryController and attempts < 50 do
		task.wait(0.1)
		attempts += 1
	end
	if _G.InventoryController and _G.InventoryController.OnSurvivalDataLoaded then
		_G.InventoryController.OnSurvivalDataLoaded(function()
			if isOpen then
				renderAllPersonalSlots()
			end
		end)
	end
end)

print("[FurnaceUI] Initialized (with embedded personal inventory + hotbar)")
