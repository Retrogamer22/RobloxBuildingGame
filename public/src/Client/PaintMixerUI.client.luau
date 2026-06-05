--[[
	PaintMixerUI
	Minecraft-style Paint Mixer station UI (Paint Mod).
	Matches CraftingTableUI / ChestUI / FurnaceUI styling.

	Flow (per design):
	  - Open by interacting with a placed Paint Mixer block.
	  - Drop an Empty Paint Can into the INPUT slot (it stays / is reusable).
	  - Set the color with the R/G/B sliders or the hex field, OR drop a Paint
	    Swatch into the SWATCH slot to pre-fill the sliders from its captured color.
	  - Choose Regular / Primer and Blend / Match.
	  - The OUTPUT slot shows a live preview of the filled can; click it to pick the
	    can up onto the cursor, then drop it into your inventory. The empty can is
	    NOT consumed, so you can keep mixing.

	The finished can is one of four hidden carrier presets (regular/primer x blend/match);
	its color rides the inventory slot's Color override, so no inventory-shape change is
	needed. Placement (BlockHandler) stamps PaintIsPrimer + PaintMode + CustomColorR/G/B
	from the carrier preset so the brush + save/load treat it like any hand-placed can.
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

local mixerColor = Color3.fromRGB(255, 255, 255)
local mixerIsPrimer = false
local mixerMode = "blend" -- "blend" | "match"

-- Items the player has deposited into the station (returned to them on close).
local inputItem = nil  -- an Empty Paint Can {p,c,n} or nil
local swatchItem = nil -- a Paint Swatch {p,c,n} or nil

local inputSlotFrame = nil
local swatchSlotFrame = nil
local outputSlotFrame = nil
local colorPreviewFrame = nil
local hexBox = nil
local sliders = {}
local primerToggleButtons = {}
local modeToggleButtons = {}

local personalSlotFrames = {}
local hotbarSlotFrames = {}

-- ============================================
-- THEME
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
	Accent = Color3.fromRGB(91, 176, 255),
	TrackBg = Color3.fromRGB(24, 24, 24),
}

local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local SLOT_SIZE = IsMobile and 40 or 46
local SLOT_PADDING = IsMobile and 3 or 4
local PERSONAL_COLS = 9
local SURVIVAL_ROWS = 4

-- ============================================
-- BEVEL HELPERS
-- ============================================
local function addBevel(frame, highlightColor, shadowColor)
	local hl = highlightColor or Color3.fromRGB(80, 80, 80)
	local sh = shadowColor or Color3.fromRGB(0, 0, 0)
	for _, def in ipairs({
		{ "BevelTop", UDim2.new(1, 0, 0, BEVEL_SIZE), UDim2.new(0, 0, 0, 0), hl },
		{ "BevelLeft", UDim2.new(0, BEVEL_SIZE, 1, 0), UDim2.new(0, 0, 0, 0), hl },
		{ "BevelBottom", UDim2.new(1, 0, 0, BEVEL_SIZE), UDim2.new(0, 0, 1, -BEVEL_SIZE), sh },
		{ "BevelRight", UDim2.new(0, BEVEL_SIZE, 1, 0), UDim2.new(1, -BEVEL_SIZE, 0, 0), sh },
	}) do
		local b = Instance.new("Frame")
		b.Name = def[1]; b.Size = def[2]; b.Position = def[3]
		b.BackgroundColor3 = def[4]; b.BackgroundTransparency = 0.3
		b.BorderSizePixel = 0; b.ZIndex = 5; b.Parent = frame
	end
end

local function addInsetBevel(frame, shadowColor, highlightColor)
	local sh = shadowColor or Color3.fromRGB(10, 10, 10)
	local hl = highlightColor or Color3.fromRGB(70, 70, 70)
	for _, def in ipairs({
		{ "BevelTop", UDim2.new(1, 0, 0, BEVEL_SIZE), UDim2.new(0, 0, 0, 0), sh },
		{ "BevelLeft", UDim2.new(0, BEVEL_SIZE, 1, 0), UDim2.new(0, 0, 0, 0), sh },
		{ "BevelBottom", UDim2.new(1, 0, 0, BEVEL_SIZE), UDim2.new(0, 0, 1, -BEVEL_SIZE), hl },
		{ "BevelRight", UDim2.new(0, BEVEL_SIZE, 1, 0), UDim2.new(1, -BEVEL_SIZE, 0, 0), hl },
	}) do
		local b = Instance.new("Frame")
		b.Name = def[1]; b.Size = def[2]; b.Position = def[3]
		b.BackgroundColor3 = def[4]; b.BackgroundTransparency = 0
		b.BorderSizePixel = 0; b.ZIndex = 5; b.Parent = frame
	end
end

-- ============================================
-- INVENTORY CONTROLLER ACCESS + HELPERS
-- ============================================
local function getInvController()
	return _G.InventoryController
end

local function colorToArray(c)
	if not c then return nil end
	return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
end

local function arrayToColor(arr)
	if arr and type(arr) == "table" then
		return Color3.fromRGB(arr[1] or 255, arr[2] or 255, arr[3] or 255)
	end
	return nil
end

local function presetIsEmptyCan(presetId)
	local p = presetId and BlockPresets.GetPreset(presetId)
	return p and p.IsEmptyCan == true
end

-- Render a block/can preview into a slot frame using InventoryController viewport helpers.
local function renderPreview(slotFrame, presetId, previewColor, isEmptyCan)
	if not slotFrame then return end
	local oldViewport = slotFrame:FindFirstChild("Viewport")
	if oldViewport then oldViewport:Destroy() end
	if not presetId then return end

	local inv = getInvController()
	if not inv or not inv.CreateViewportPreview or not inv.SetupViewportModel then return end
	local preset = BlockPresets.GetPreset(presetId)
	if not preset then return end
	local shape = BlockPresets.GetShape(preset.Shape)
	if not shape then return end

	local viewport = inv.CreateViewportPreview(slotFrame, UDim2.new(1, -6, 1, -6))
	viewport.Position = UDim2.new(0, 3, 0, 3)
	viewport.ZIndex = 4

	inv.SetupViewportModel(
		viewport, shape.TemplateName, previewColor or preset.DefaultColor,
		preset.Material, preset.MaterialVariant,
		preset.UseBlockModel, preset.BlockModelName,
		preset.IsDecoration, preset.DecorationName,
		preset.BlockModelFolder, preset.ApplyColor, preset.LeatherTint,
		nil, nil, isEmptyCan == true
	)
end

-- ============================================
-- PERSONAL INVENTORY SLOT HELPERS (mirror CraftingTableUI)
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
			countLabel.Text = tostring(data.n); countLabel.Visible = true
		else
			countLabel.Visible = false
		end
	end
	renderPreview(slotFrame, data.p, arrayToColor(data.c), presetIsEmptyCan(data.p))
end

local function renderAllPersonalSlots()
	local inv = getInvController()
	if not inv then return end
	local slotCount = inv.GetSurvivalSlotCount and inv.GetSurvivalSlotCount() or 36
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
		local newItem = { p = heldItem.PresetId, c = colorToArray(heldItem.Color), n = heldItem.Count or 1 }
		if existingItem and existingItem.p then
			inv.SetSurvivalSlot(slotIndex, newItem)
			updatePersonalSlotViewport(slotIndex)
			local existColor = arrayToColor(existingItem.c)
			inv.DiscardHeld()
			inv.PickUpItem(existingItem.p, existColor, nil, existingItem.n or 1)
		else
			inv.SetSurvivalSlot(slotIndex, newItem)
			updatePersonalSlotViewport(slotIndex)
			inv.DiscardHeld()
		end
	else
		if existingItem and existingItem.p then
			inv.SetSurvivalSlot(slotIndex, nil)
			updatePersonalSlotViewport(slotIndex)
			inv.PickUpItem(existingItem.p, arrayToColor(existingItem.c), nil, existingItem.n or 1)
		end
	end
end

-- ============================================
-- HOTBAR SLOT HELPERS (mirror CraftingTableUI)
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
			countLabel.Text = tostring(data.n); countLabel.Visible = true
		else
			countLabel.Visible = false
		end
	end
	renderPreview(slotFrame, data.p, arrayToColor(data.c), presetIsEmptyCan(data.p))
end

local function renderAllHotbarSlots()
	local inv = getInvController()
	if not inv or not inv.GetHotbarSize then return end
	for i = 1, inv.GetHotbarSize() do
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
		if existingItem and existingItem.isTool then return end
		local newItem = { p = heldItem.PresetId, c = colorToArray(heldItem.Color), n = heldItem.Count or 1 }
		if existingItem and existingItem.p then
			inv.SetHotbarSlot(slotIndex, newItem)
			updateHotbarSlotViewport(slotIndex)
			local existColor = arrayToColor(existingItem.c)
			inv.DiscardHeld()
			inv.PickUpItem(existingItem.p, existColor, nil, existingItem.n or 1)
		else
			inv.SetHotbarSlot(slotIndex, newItem)
			updateHotbarSlotViewport(slotIndex)
			inv.DiscardHeld()
		end
	else
		if existingItem and existingItem.p and not existingItem.isTool then
			inv.SetHotbarSlot(slotIndex, nil)
			updateHotbarSlotViewport(slotIndex)
			inv.PickUpItem(existingItem.p, arrayToColor(existingItem.c), nil, existingItem.n or 1)
		end
	end
end

-- ============================================
-- SHIFT-CLICK QUICK-ROUTE INTO THE MIXER
-- Shift-clicking an inventory item routes it to the matching station slot (empty can -> input,
-- swatch -> swatch) if that slot is empty. shiftRouteToMixer is forward-declared here and
-- assigned once the mixer-logic helpers (renderSpecialSlots etc.) exist further down.
-- ============================================
local function isShiftHeld()
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local function clearMixerSourceSlot(slotIndex, kind)
	local inv = getInvController()
	if not inv then return end
	if kind == "Personal" then
		inv.SetSurvivalSlot(slotIndex, nil)
		updatePersonalSlotViewport(slotIndex)
	else
		inv.SetHotbarSlot(slotIndex, nil)
		updateHotbarSlotViewport(slotIndex)
	end
end

local shiftRouteToMixer -- assigned after the mixer-logic helpers are defined

-- ============================================
-- GENERIC INVENTORY SLOT BUILDER (mirror CraftingTableUI)
-- ============================================
local function createInteractiveSlot(parent, x, y, slotIndex, kind)
	local slot = Instance.new("TextButton")
	slot.Name = kind .. "Slot_" .. slotIndex
	slot.Size = UDim2.new(0, SLOT_SIZE, 0, SLOT_SIZE)
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
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(30, 30, 30)
	stroke.Thickness = 1.5
	stroke.Parent = countLabel

	slot.MouseEnter:Connect(function() slot.BackgroundColor3 = Colors.CellHover end)
	slot.MouseLeave:Connect(function() slot.BackgroundColor3 = Colors.CellBg end)

	local function getItem()
		local inv = getInvController()
		if not inv then return nil end
		if kind == "Personal" then
			local survSlots = inv.GetSurvivalSlots() or {}
			return survSlots[slotIndex]
		else
			return inv.GetHotbarSlot and inv.GetHotbarSlot(slotIndex)
		end
	end

	local function onClick()
		if kind == "Personal" then onPersonalSlotClick(slotIndex) else onHotbarSlotClick(slotIndex) end
	end

	local pressStart, longFired = nil, false
	slot.MouseButton1Down:Connect(function()
		pressStart = tick(); longFired = false
		if IsMobile and not (getInvController() and getInvController().IsHolding()) then
			local st = pressStart
			task.delay(0.35, function()
				if pressStart == st and not longFired and isOpen then
					longFired = true
					local item = getItem()
					if item and item.p and not item.isTool then onClick() end
				end
			end)
		end
	end)
	slot.MouseButton1Up:Connect(function() pressStart = nil end)
	slot.MouseButton1Click:Connect(function()
		if longFired then return end
		local inv = getInvController()
		-- Shift-click (desktop): route empty cans -> input slot, swatches -> swatch slot.
		if not IsMobile and isShiftHeld() and inv and not (inv.IsHolding and inv.IsHolding()) then
			local item = getItem()
			if item and item.p and not item.isTool and shiftRouteToMixer then
				if shiftRouteToMixer(item, slotIndex, kind) then return end
			end
		end
		if IsMobile and inv and not inv.IsHolding() then return end
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
-- MIXER LOGIC
-- ============================================
local function carrierIdFor(isPrimer, mode)
	if isPrimer then
		return (mode == "match") and "MixedPrimerPaintCanMatch" or "MixedPrimerPaintCan"
	else
		return (mode == "match") and "MixedPaintCanMatch" or "MixedPaintCan"
	end
end

local function updateColorPreview()
	if colorPreviewFrame then colorPreviewFrame.BackgroundColor3 = mixerColor end
	if hexBox and not hexBox:IsFocused() then
		hexBox.Text = string.format("#%02X%02X%02X",
			math.floor(mixerColor.R * 255 + 0.5),
			math.floor(mixerColor.G * 255 + 0.5),
			math.floor(mixerColor.B * 255 + 0.5))
	end
end

local function updateOutputPreview()
	if not outputSlotFrame then return end
	if not inputItem then
		renderPreview(outputSlotFrame, nil)
		return
	end
	renderPreview(outputSlotFrame, carrierIdFor(mixerIsPrimer, mixerMode), mixerColor, false)
end

local function renderSpecialSlots()
	renderPreview(inputSlotFrame, inputItem and inputItem.p or nil, inputItem and arrayToColor(inputItem.c) or nil, true)
	renderPreview(swatchSlotFrame, swatchItem and swatchItem.p or nil, swatchItem and arrayToColor(swatchItem.c) or nil, false)
	updateOutputPreview()
end

local function recomputeFromSliders()
	if not (sliders.R and sliders.G and sliders.B) then return end
	mixerColor = Color3.fromRGB(sliders.R.get(), sliders.G.get(), sliders.B.get())
	updateColorPreview()
	updateOutputPreview()
end

local function setSlidersFromColor(c)
	if sliders.R then sliders.R.set(math.floor(c.R * 255 + 0.5)) end
	if sliders.G then sliders.G.set(math.floor(c.G * 255 + 0.5)) end
	if sliders.B then sliders.B.set(math.floor(c.B * 255 + 0.5)) end
	mixerColor = c
	updateColorPreview()
	updateOutputPreview()
end

-- Prefill the sliders from a swatch item. Swatches are per-slot now, so the item's own color
-- (it.c) is preferred; the global captured color is a fallback for older/edge cases.
local function applySwatchPrefill(it)
	if not it then return end
	if it.c then
		setSlidersFromColor(arrayToColor(it.c))
		return
	end
	local r = player:GetAttribute("SwatchColorR")
	local g = player:GetAttribute("SwatchColorG")
	local b = player:GetAttribute("SwatchColorB")
	if player:GetAttribute("SwatchLoaded") and r and g and b then
		setSlidersFromColor(Color3.fromRGB(r, g, b))
	end
end

-- Assign the forward-declared router now that the helpers it needs exist. Shift-clicking an
-- empty can sends it to the (empty) input slot; a swatch goes to the (empty) swatch slot and
-- prefills the sliders. Returns true if it consumed the click.
shiftRouteToMixer = function(item, slotIndex, kind)
	if not item or not item.p then return false end
	if presetIsEmptyCan(item.p) and not inputItem then
		inputItem = { p = item.p, c = item.c, n = item.n or 1 }
		clearMixerSourceSlot(slotIndex, kind)
		renderSpecialSlots()
		return true
	end
	local preset = BlockPresets.GetPreset(item.p)
	if preset and preset.IsSwatch and not swatchItem then
		swatchItem = { p = item.p, c = item.c, n = item.n or 1 }
		clearMixerSourceSlot(slotIndex, kind)
		renderSpecialSlots()
		applySwatchPrefill(swatchItem)
		return true
	end
	return false
end

local function setPrimer(isPrimer)
	mixerIsPrimer = isPrimer and true or false
	for flag, btn in pairs(primerToggleButtons) do
		local on = (flag == mixerIsPrimer)
		btn.BackgroundColor3 = on and Colors.Accent or Colors.CellBg
		btn.TextColor3 = on and Color3.fromRGB(6, 16, 24) or Colors.TextMuted
	end
	updateOutputPreview()
end

local function setMode(mode)
	mixerMode = (mode == "match") and "match" or "blend"
	for m, btn in pairs(modeToggleButtons) do
		local on = (m == mixerMode)
		btn.BackgroundColor3 = on and Colors.Accent or Colors.CellBg
		btn.TextColor3 = on and Color3.fromRGB(6, 16, 24) or Colors.TextMuted
	end
	updateOutputPreview()
end

-- ============================================
-- SLIDER BUILDER (draggable R/G/B)
-- ============================================
local function makeSlider(parent, x, y, width, labelText, labelColor, initial)
	local HANDLE = 14
	local TRACK_H = 8

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0, 14, 0, 18)
	lbl.Position = UDim2.new(0, x, 0, y)
	lbl.BackgroundTransparency = 1
	lbl.Text = labelText
	lbl.TextColor3 = labelColor
	lbl.TextSize = 13
	lbl.Font = FONT
	lbl.ZIndex = 3
	lbl.Parent = parent

	local trackX = x + 20
	local trackW = width - 20 - 38
	local track = Instance.new("Frame")
	track.Name = "Track_" .. labelText
	track.Size = UDim2.new(0, trackW, 0, TRACK_H)
	track.Position = UDim2.new(0, trackX, 0, y + 5)
	track.BackgroundColor3 = Colors.TrackBg
	track.BorderSizePixel = 0
	track.ZIndex = 3
	track.Parent = parent
	addInsetBevel(track)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = labelColor
	fill.BorderSizePixel = 0
	fill.ZIndex = 4
	fill.Parent = track

	local handle = Instance.new("TextButton")
	handle.Name = "Handle"
	handle.Size = UDim2.new(0, HANDLE, 0, HANDLE)
	handle.AnchorPoint = Vector2.new(0.5, 0.5)
	handle.Position = UDim2.new(0, 0, 0.5, 0)
	handle.BackgroundColor3 = Color3.fromRGB(230, 230, 230)
	handle.BorderSizePixel = 0
	handle.Text = ""
	handle.AutoButtonColor = false
	handle.ZIndex = 6
	handle.Parent = track
	addBevel(handle, Color3.fromRGB(255, 255, 255), Color3.fromRGB(120, 120, 120))

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Size = UDim2.new(0, 34, 0, 18)
	valueLabel.Position = UDim2.new(0, trackX + trackW + 4, 0, y)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Text = "0"
	valueLabel.TextColor3 = Colors.Text
	valueLabel.TextSize = 12
	valueLabel.Font = FONT
	valueLabel.TextXAlignment = Enum.TextXAlignment.Left
	valueLabel.ZIndex = 3
	valueLabel.Parent = parent

	local value = 0
	local dragging = false

	local function applyFraction(frac, fireChange)
		frac = math.clamp(frac, 0, 1)
		value = math.floor(frac * 255 + 0.5)
		fill.Size = UDim2.new(frac, 0, 1, 0)
		handle.Position = UDim2.new(frac, 0, 0.5, 0)
		valueLabel.Text = tostring(value)
		if fireChange then recomputeFromSliders() end
	end

	local function updateFromX(inputX)
		local absPos = track.AbsolutePosition.X
		local absW = track.AbsoluteSize.X
		if absW <= 0 then return end
		applyFraction((inputX - absPos) / absW, true)
	end

	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			updateFromX(input.Position.X)
		end
	end)
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			updateFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	applyFraction((initial or 0) / 255, false)

	return {
		set = function(v) applyFraction((v or 0) / 255, false) end,
		get = function() return value end,
	}
end

local function makeToggleButton(parent, x, y, w, h, text)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0, w, 0, h)
	btn.Position = UDim2.new(0, x, 0, y)
	btn.BackgroundColor3 = Colors.CellBg
	btn.BorderSizePixel = 0
	btn.Text = text
	btn.TextColor3 = Colors.TextMuted
	btn.TextSize = 13
	btn.Font = FONT
	btn.AutoButtonColor = false
	btn.ZIndex = 3
	btn.Parent = parent
	addInsetBevel(btn)
	return btn
end

-- A special slot (input empty-can / swatch) deposit/withdraw handler.
-- accept(item) -> bool decides whether a held item may be deposited.
-- get()/set(item) read/write the backing state. onDeposit(item) is called after deposit.
local function wireSpecialSlot(slot, accept, get, set, onChange)
	slot.MouseButton1Click:Connect(function()
		local inv = getInvController()
		if not inv then return end
		local held = inv.IsHolding and inv.IsHolding() and inv.GetHeldItem()
		local current = get()
		if held then
			if not accept(held.PresetId) then return end
			-- Deposit held into this slot; swap out anything already here.
			local newItem = { p = held.PresetId, c = colorToArray(held.Color), n = held.Count or 1 }
			inv.DiscardHeld()
			set(newItem)
			if current then
				inv.PickUpItem(current.p, arrayToColor(current.c), nil, current.n or 1)
			end
			if onChange then onChange(newItem) end
		else
			-- Withdraw to cursor.
			if current then
				set(nil)
				inv.PickUpItem(current.p, arrayToColor(current.c), nil, current.n or 1)
				if onChange then onChange(nil) end
			end
		end
		renderSpecialSlots()
	end)
	slot.MouseButton2Click:Connect(function()
		local inv = getInvController()
		if not inv then return end
		local current = get()
		if current and not (inv.IsHolding and inv.IsHolding()) then
			set(nil)
			inv.PickUpItem(current.p, arrayToColor(current.c), nil, current.n or 1)
			if onChange then onChange(nil) end
			renderSpecialSlots()
		end
	end)
end

-- ============================================
-- BUILD UI (one-time)
-- ============================================
local function buildUI()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PaintMixerUI"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 16
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	local overlay = Instance.new("TextButton")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.5
	overlay.Text = ""
	overlay.AutoButtonColor = false
	overlay.ZIndex = 1
	overlay.Parent = screenGui
	overlay.MouseButton1Click:Connect(function()
		local inv = getInvController()
		if inv and inv.IsHolding and inv.IsHolding() then return end
		if isOpen then _G.PaintMixerUI.Close() end
	end)

	local controlsY = 50
	local controlsH = 130
	local toggleRowH = 36
	local invGridH = SURVIVAL_ROWS * (SLOT_SIZE + SLOT_PADDING) + 6
	local hotbarH = SLOT_SIZE + 12
	local panelW = math.max(560, PERSONAL_COLS * (SLOT_SIZE + SLOT_PADDING) + 40)
	local panelH = controlsY + controlsH + toggleRowH + 30 + invGridH + 26 + hotbarH + 22

	mainFrame = Instance.new("Frame")
	mainFrame.Name = "MainFrame"
	mainFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	mainFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
	mainFrame.Size = UDim2.new(0, panelW, 0, panelH)
	mainFrame.BackgroundColor3 = Colors.Background
	mainFrame.BorderSizePixel = 0
	mainFrame.ZIndex = 2
	mainFrame.Parent = screenGui
	addBevel(mainFrame)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -60, 0, 30)
	title.Position = UDim2.new(0, 16, 0, 12)
	title.BackgroundTransparency = 1
	title.Text = "Paint Mixer"
	title.TextColor3 = Colors.Text
	title.TextSize = 20
	title.Font = FONT
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 3
	title.Parent = mainFrame

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.new(0, 28, 0, 28)
	closeBtn.Position = UDim2.new(1, -40, 0, 12)
	closeBtn.BackgroundColor3 = Colors.Danger
	closeBtn.BorderSizePixel = 0
	closeBtn.Text = "X"
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.TextSize = 16
	closeBtn.Font = FONT
	closeBtn.AutoButtonColor = false
	closeBtn.ZIndex = 3
	closeBtn.Parent = mainFrame
	addBevel(closeBtn, Color3.fromRGB(255, 130, 130), Color3.fromRGB(110, 20, 20))
	closeBtn.MouseButton1Click:Connect(function()
		if isOpen then _G.PaintMixerUI.Close() end
	end)

	-- Input + swatch slots (left)
	inputSlotFrame = (function()
		local container = Instance.new("Frame")
		container.Size = UDim2.new(0, SLOT_SIZE + 4, 0, SLOT_SIZE + 22)
		container.Position = UDim2.new(0, 16, 0, controlsY)
		container.BackgroundTransparency = 1
		container.ZIndex = 3
		container.Parent = mainFrame
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 10, 0, 14)
		label.BackgroundTransparency = 1
		label.Text = "Empty Can"
		label.TextColor3 = Colors.TextMuted
		label.TextSize = 11
		label.Font = FONT
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.ZIndex = 3
		label.Parent = container
		local slot = Instance.new("TextButton")
		slot.Name = "Slot"
		slot.Size = UDim2.new(0, SLOT_SIZE + 4, 0, SLOT_SIZE + 4)
		slot.Position = UDim2.new(0, 0, 0, 16)
		slot.BackgroundColor3 = Colors.CellBg
		slot.BorderSizePixel = 0
		slot.Text = ""
		slot.AutoButtonColor = false
		slot.ZIndex = 3
		slot.Parent = container
		addInsetBevel(slot)
		slot.MouseEnter:Connect(function() slot.BackgroundColor3 = Colors.CellHover end)
		slot.MouseLeave:Connect(function() slot.BackgroundColor3 = Colors.CellBg end)
		return slot
	end)()

	swatchSlotFrame = (function()
		local container = Instance.new("Frame")
		container.Size = UDim2.new(0, SLOT_SIZE + 4, 0, SLOT_SIZE + 22)
		container.Position = UDim2.new(0, 16 + SLOT_SIZE + 18, 0, controlsY)
		container.BackgroundTransparency = 1
		container.ZIndex = 3
		container.Parent = mainFrame
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 10, 0, 14)
		label.BackgroundTransparency = 1
		label.Text = "Swatch"
		label.TextColor3 = Colors.TextMuted
		label.TextSize = 11
		label.Font = FONT
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.ZIndex = 3
		label.Parent = container
		local slot = Instance.new("TextButton")
		slot.Name = "Slot"
		slot.Size = UDim2.new(0, SLOT_SIZE + 4, 0, SLOT_SIZE + 4)
		slot.Position = UDim2.new(0, 0, 0, 16)
		slot.BackgroundColor3 = Colors.CellBg
		slot.BorderSizePixel = 0
		slot.Text = ""
		slot.AutoButtonColor = false
		slot.ZIndex = 3
		slot.Parent = container
		addInsetBevel(slot)
		slot.MouseEnter:Connect(function() slot.BackgroundColor3 = Colors.CellHover end)
		slot.MouseLeave:Connect(function() slot.BackgroundColor3 = Colors.CellBg end)
		return slot
	end)()

	-- Sliders (middle)
	local slidersX = 16 + 2 * (SLOT_SIZE + 18) + 8
	local outputSize = SLOT_SIZE + 10
	local slidersW = panelW - slidersX - 16 - outputSize - 40
	sliders.R = makeSlider(mainFrame, slidersX, controlsY + 2, slidersW, "R", Color3.fromRGB(220, 90, 90), 255)
	sliders.G = makeSlider(mainFrame, slidersX, controlsY + 30, slidersW, "G", Color3.fromRGB(110, 200, 110), 255)
	sliders.B = makeSlider(mainFrame, slidersX, controlsY + 58, slidersW, "B", Color3.fromRGB(110, 150, 230), 255)

	-- Color preview + hex (below sliders)
	colorPreviewFrame = Instance.new("Frame")
	colorPreviewFrame.Size = UDim2.new(0, 26, 0, 26)
	colorPreviewFrame.Position = UDim2.new(0, slidersX, 0, controlsY + 90)
	colorPreviewFrame.BackgroundColor3 = mixerColor
	colorPreviewFrame.BorderSizePixel = 0
	colorPreviewFrame.ZIndex = 3
	colorPreviewFrame.Parent = mainFrame
	addInsetBevel(colorPreviewFrame)

	hexBox = Instance.new("TextBox")
	hexBox.Size = UDim2.new(0, 96, 0, 26)
	hexBox.Position = UDim2.new(0, slidersX + 34, 0, controlsY + 90)
	hexBox.BackgroundColor3 = Colors.CellBg
	hexBox.BorderSizePixel = 0
	hexBox.Text = "#FFFFFF"
	hexBox.PlaceholderText = "#RRGGBB"
	hexBox.TextColor3 = Colors.Text
	hexBox.TextSize = 14
	hexBox.Font = Enum.Font.Code
	hexBox.ClearTextOnFocus = false
	hexBox.ZIndex = 3
	hexBox.Parent = mainFrame
	addInsetBevel(hexBox)
	hexBox.FocusLost:Connect(function()
		local hex = hexBox.Text:gsub("#", ""):gsub("%s", "")
		if #hex == 6 then
			local r = tonumber(hex:sub(1, 2), 16)
			local g = tonumber(hex:sub(3, 4), 16)
			local b = tonumber(hex:sub(5, 6), 16)
			if r and g and b then
				setSlidersFromColor(Color3.fromRGB(r, g, b))
				return
			end
		end
		updateColorPreview()
	end)

	-- Arrow + output slot (right)
	local outputX = panelW - 16 - outputSize
	local outputY = controlsY + 16
	local arrow = Instance.new("TextLabel")
	arrow.Size = UDim2.new(0, 28, 0, 20)
	arrow.Position = UDim2.new(0, outputX - 32, 0, outputY + outputSize / 2 - 10)
	arrow.BackgroundTransparency = 1
	arrow.Text = "==>"
	arrow.TextColor3 = Colors.ArrowColor
	arrow.TextSize = 16
	arrow.Font = FONT
	arrow.ZIndex = 3
	arrow.Parent = mainFrame

	outputSlotFrame = Instance.new("TextButton")
	outputSlotFrame.Name = "OutputSlot"
	outputSlotFrame.Size = UDim2.new(0, outputSize, 0, outputSize)
	outputSlotFrame.Position = UDim2.new(0, outputX, 0, outputY)
	outputSlotFrame.BackgroundColor3 = Colors.CellBg
	outputSlotFrame.BorderSizePixel = 0
	outputSlotFrame.Text = ""
	outputSlotFrame.AutoButtonColor = false
	outputSlotFrame.ZIndex = 3
	outputSlotFrame.Parent = mainFrame
	addInsetBevel(outputSlotFrame)
	outputSlotFrame.MouseEnter:Connect(function() outputSlotFrame.BackgroundColor3 = Colors.CellHover end)
	outputSlotFrame.MouseLeave:Connect(function() outputSlotFrame.BackgroundColor3 = Colors.CellBg end)
	outputSlotFrame.MouseButton1Click:Connect(function()
		local inv = getInvController()
		if not inv then return end
		if not inputItem then return end -- need an empty can in the input slot
		local carrierId = carrierIdFor(mixerIsPrimer, mixerMode)
		local function flashOutput()
			local orig = outputSlotFrame.BackgroundColor3
			outputSlotFrame.BackgroundColor3 = Colors.Success
			task.delay(0.15, function()
				TweenService:Create(outputSlotFrame, TweenInfo.new(0.2), { BackgroundColor3 = orig }):Play()
			end)
		end
		-- Shift-click: send the finished can straight to the next open inventory slot (hotbar
		-- first, then personal inventory) instead of onto the cursor.
		if not IsMobile and isShiftHeld() then
			local granted = inv.GrantItem and inv.GrantItem(carrierId, mixerColor, 1)
			if not granted and inv.QuickTransferToSurvival then
				granted = inv.QuickTransferToSurvival({ p = carrierId, c = colorToArray(mixerColor), n = 1 })
			end
			if granted then flashOutput() end
			return
		end
		if inv.IsHolding and inv.IsHolding() then return end -- already carrying something
		-- Hand the finished can to the cursor; the empty can stays (reusable).
		inv.PickUpItem(carrierId, mixerColor, nil, 1)
		flashOutput()
	end)

	-- Wire the input + swatch deposit/withdraw behavior.
	wireSpecialSlot(inputSlotFrame,
		function(pid) return presetIsEmptyCan(pid) end,
		function() return inputItem end,
		function(it) inputItem = it end,
		function() updateOutputPreview() end)

	wireSpecialSlot(swatchSlotFrame,
		function(pid)
			local p = pid and BlockPresets.GetPreset(pid)
			return p and p.IsSwatch == true
		end,
		function() return swatchItem end,
		function(it) swatchItem = it end,
		function(it)
			-- Pre-fill the sliders from the dropped swatch's color (shared with shift-click route).
			applySwatchPrefill(it)
		end)

	-- ======== TOGGLES (Regular/Primer + Blend/Match) ========
	local toggleY = controlsY + controlsH
	local tBtnW = 84
	local tBtnH = 28
	local regBtn = makeToggleButton(mainFrame, 16, toggleY, tBtnW, tBtnH, "Regular")
	local primBtn = makeToggleButton(mainFrame, 16 + tBtnW + 4, toggleY, tBtnW, tBtnH, "Primer")
	primerToggleButtons[false] = regBtn
	primerToggleButtons[true] = primBtn
	regBtn.MouseButton1Click:Connect(function() setPrimer(false) end)
	primBtn.MouseButton1Click:Connect(function() setPrimer(true) end)

	local blendX = 16 + 2 * (tBtnW + 4) + 28
	local blendBtn = makeToggleButton(mainFrame, blendX, toggleY, tBtnW, tBtnH, "Blend")
	local matchBtn = makeToggleButton(mainFrame, blendX + tBtnW + 4, toggleY, tBtnW, tBtnH, "Match")
	modeToggleButtons["blend"] = blendBtn
	modeToggleButtons["match"] = matchBtn
	blendBtn.MouseButton1Click:Connect(function() setMode("blend") end)
	matchBtn.MouseButton1Click:Connect(function() setMode("match") end)

	-- ======== SEPARATOR + EMBEDDED INVENTORY ========
	local invTop = toggleY + toggleRowH + 18
	local sep = Instance.new("Frame")
	sep.Size = UDim2.new(1, -32, 0, 1)
	sep.Position = UDim2.new(0, 16, 0, invTop - 10)
	sep.BackgroundColor3 = Colors.BorderHighlight
	sep.BackgroundTransparency = 0.5
	sep.BorderSizePixel = 0
	sep.ZIndex = 3
	sep.Parent = mainFrame

	local invLabel = Instance.new("TextLabel")
	invLabel.Size = UDim2.new(0, 200, 0, 16)
	invLabel.Position = UDim2.new(0, 16, 0, invTop - 6)
	invLabel.BackgroundTransparency = 1
	invLabel.Text = "Inventory"
	invLabel.TextColor3 = Colors.Text
	invLabel.TextSize = 13
	invLabel.Font = FONT
	invLabel.TextXAlignment = Enum.TextXAlignment.Left
	invLabel.ZIndex = 3
	invLabel.Parent = mainFrame

	local inv = getInvController()
	local survCount = (inv and inv.GetSurvivalSlotCount and inv.GetSurvivalSlotCount()) or 36
	local gridStartY = invTop + 14
	local gridStartX = (panelW - (PERSONAL_COLS * (SLOT_SIZE + SLOT_PADDING) - SLOT_PADDING)) / 2
	for i = 1, survCount do
		local col = (i - 1) % PERSONAL_COLS
		local row = math.floor((i - 1) / PERSONAL_COLS)
		local x = gridStartX + col * (SLOT_SIZE + SLOT_PADDING)
		local y = gridStartY + row * (SLOT_SIZE + SLOT_PADDING)
		personalSlotFrames[i] = createInteractiveSlot(mainFrame, x, y, i, "Personal")
	end

	local hotbarSize = (inv and inv.GetHotbarSize and inv.GetHotbarSize()) or 9
	local hotbarY = gridStartY + SURVIVAL_ROWS * (SLOT_SIZE + SLOT_PADDING) + 10
	local hotbarStartX = (panelW - (hotbarSize * (SLOT_SIZE + SLOT_PADDING) - SLOT_PADDING)) / 2
	for i = 1, hotbarSize do
		local x = hotbarStartX + (i - 1) * (SLOT_SIZE + SLOT_PADDING)
		hotbarSlotFrames[i] = createInteractiveSlot(mainFrame, x, hotbarY, i, "Hotbar")
	end
end

-- ============================================
-- OPEN / CLOSE
-- ============================================
local function openUI(block)
	if isOpen then return end
	isOpen = true
	currentBlock = block

	-- Fresh session: clear deposits + reset controls to white / regular / blend.
	inputItem = nil
	swatchItem = nil
	setPrimer(false)
	setMode("blend")
	setSlidersFromColor(Color3.fromRGB(255, 255, 255))
	renderSpecialSlots()

	screenGui.Enabled = true

	local blur = Lighting:FindFirstChild("PaintMixerUIBlur")
	if not blur then
		blur = Instance.new("BlurEffect")
		blur.Name = "PaintMixerUIBlur"
		blur.Parent = Lighting
	end
	blur.Size = 12

	local inv = getInvController()
	if inv then
		if inv.IsSurvivalLoaded and inv.IsSurvivalLoaded() then
			renderAllPersonalSlots()
		elseif inv.RequestSurvivalData then
			inv.RequestSurvivalData()
		end
		renderAllHotbarSlots()
		if inv.SetHotbarVisible then inv.SetHotbarVisible(false) end
	end
end

local function returnDeposited()
	local inv = getInvController()
	if not inv or not inv.GrantItem then
		inputItem, swatchItem = nil, nil
		return
	end
	-- Return deposited can/swatch so they aren't lost. If the hotbar is full, GrantItem
	-- returns false; the item is dropped from the station (rare; hotbar usually has room).
	if inputItem then
		inv.GrantItem(inputItem.p, arrayToColor(inputItem.c), inputItem.n or 1)
		inputItem = nil
	end
	if swatchItem then
		inv.GrantItem(swatchItem.p, arrayToColor(swatchItem.c), swatchItem.n or 1)
		swatchItem = nil
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

	returnDeposited()

	screenGui.Enabled = false
	local blur = Lighting:FindFirstChild("PaintMixerUIBlur")
	if blur then blur.Size = 0 end

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
	if gameProcessed then return end -- don't close while typing in the hex field
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

_G.PaintMixerUI = {
	IsOpen = function() return isOpen end,
	Open = function(block) openUI(block) end,
	Close = function() closeUI() end,
	GetCurrentBlock = function() return currentBlock end,
}

task.defer(function()
	local attempts = 0
	while not _G.InventoryController and attempts < 50 do
		task.wait(0.1)
		attempts += 1
	end
	if _G.InventoryController and _G.InventoryController.OnSurvivalDataLoaded then
		_G.InventoryController.OnSurvivalDataLoaded(function()
			if isOpen then renderAllPersonalSlots() end
		end)
	end
end)

print("[PaintMixerUI] Initialized (embedded inventory + hotbar)")
