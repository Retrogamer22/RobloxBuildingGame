--[[
	ChestUI
	Minecraft-style chest inventory UI with functional drag-and-drop
	Matches InventoryController dark theme styling
	- Opens when player interacts with a placed chest
	- 27 slots (3 rows x 9 cols) for single chest
	- 54 slots (6 rows x 9 cols) for double chest
	- Drag items between hotbar and chest slots
	- Server-side persistence via ChestHandler
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

local BlockTemplates = ReplicatedStorage:WaitForChild("BlockTemplates", 10)
local BlocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)
local DecorationsFolder = ReplicatedStorage:FindFirstChild("Decorations")
local FrameBlocksFolder = ReplicatedStorage:FindFirstChild("FrameBlocks")

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local RequestChestContents = nil
local ChestContentsResponse = nil
local UpdateChestSlot = nil

-- ============================================
-- STATE
-- ============================================
local isOpen = false
local currentChestBlock = nil
local screenGui = nil
local mainFrame = nil
local onCloseCallback = nil

-- Chest slot data: [slotIndex] = {p = "PresetId", c = {R,G,B}} or nil
local chestSlots = {}
local chestSlotFrames = {} -- [slotIndex] = TextButton frame
local totalSlots = 27

-- Personal inventory slot frames (embedded below chest grid)
local personalSlotFrames = {} -- [slotIndex] = TextButton frame
local PERSONAL_COLS = 9

-- Hotbar slot frames (embedded below personal inventory in side-by-side mode)
local hotbarSlotFrames = {} -- [slotIndex] = TextButton frame
local HOTBAR_COLS = 10

-- Track items picked up from chest (for cancel/return on close)
local pickedFromChestSlot = nil -- slot index if current held item came from this chest

-- Get darkened wood color from a chest/crafting block for UI theming
local function getBlockUIColor(block)
	if not block then return nil end
	
	-- Try custom color attributes first
	local cr = block:GetAttribute("CustomColorR")
	local cg = block:GetAttribute("CustomColorG")
	local cb = block:GetAttribute("CustomColorB")
	if cr and cg and cb then
		return Color3.fromRGB(cr, cg, cb)
	end
	
	-- Fall back to preset default color
	local blockType = block:GetAttribute("BlockType")
	if blockType and BlockPresets then
		local preset = BlockPresets.GetPreset(blockType)
		if preset and preset.DefaultColor then
			return preset.DefaultColor
		end
	end
	
	return nil
end

local function darkenColor(color, factor)
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, math.min(s * 1.2, 1), v * factor)
end

-- ============================================
-- DARK MODE COLOR THEME (matches InventoryController)
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
}

-- Mobile detection: touch-only devices get the side-by-side layout (chest left,
-- personal inventory right) which fits landscape phones way better than the
-- desktop stacked layout. Slot size is computed dynamically to pack as large as
-- possible while still fitting both grids on screen.
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
local SideBySide = IsMobile

local SLOT_PADDING = IsMobile and 2 or 3
local COLS = 9
local SINGLE_ROWS = 3
local DOUBLE_ROWS = 6

-- Compute the largest slot size that fits the current screen.
-- Side-by-side panel width math:
--   panelW = panelPad*2 + (gridContainer + gap + gridContainer)
--   gridContainer = 9*S + 8*P + 12 (6px inset on each side)
--   gap = 16
--   → panelW = 32 + 16 + 2*(9*S + 8*P + 12) = 72 + 18*S + 16*P
-- Stacked: only one grid wide, no math needed (panel fits whatever cols dictate)
local function computeSlotSize()
	if not IsMobile then return 52 end
	local cam = workspace.CurrentCamera
	local screenW = (cam and cam.ViewportSize.X) or 800
	if screenW < 100 then screenW = 800 end -- guard against stale viewport at load
	if SideBySide then
		-- Leave 16px margin from screen edge on each side
		local maxS = math.floor((screenW - 32 - 72 - 16 * SLOT_PADDING) / 18)
		return math.clamp(maxS, 28, 42)
	else
		return 38
	end
end

local SLOT_SIZE = computeSlotSize()

-- ============================================
-- BEVEL HELPERS (matches InventoryController)
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
-- VIEWPORT PREVIEW HELPERS
-- ============================================

-- Wait for InventoryController to be ready (it exposes viewport helpers)
local function getInvController()
	return _G.InventoryController
end

local function updateSlotViewport(slotIndex)
	local slotFrame = chestSlotFrames[slotIndex]
	if not slotFrame then return end
	
	-- Clear existing viewport
	local oldViewport = slotFrame:FindFirstChild("Viewport")
	if oldViewport then oldViewport:Destroy() end
	
	-- Update count label
	local countLabel = slotFrame:FindFirstChild("CountLabel")
	
	local data = chestSlots[slotIndex]
	if not data or not data.p then
		if countLabel then countLabel.Visible = false end
		return
	end
	
	-- Show count if > 1
	if countLabel then
		if data.n and data.n > 1 then
			countLabel.Text = tostring(data.n)
			countLabel.Visible = true
		else
			countLabel.Visible = false
		end
	end
	
	local inv = getInvController()
	if not inv or not inv.CreateViewportPreview or not inv.SetupViewportModel then return end
	
	local preset = BlockPresets.GetPreset(data.p)
	if not preset then return end
	
	-- Determine color
	local color = nil
	if data.c and type(data.c) == "table" then
		color = Color3.fromRGB(data.c[1] or 255, data.c[2] or 255, data.c[3] or 255)
	elseif preset.Color then
		color = preset.Color
	end
	
	local viewport = inv.CreateViewportPreview(slotFrame, UDim2.new(1, -6, 1, -6))
	viewport.Position = UDim2.new(0, 3, 0, 3)
	viewport.ZIndex = 4
	
	-- Look up template via the shape system (most blocks rely on this rather
	-- than setting TemplateName directly on the preset). Without this, blocks
	-- that use a shape were silently failing to render in chest slots.
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

-- ============================================
-- SLOT INTERACTION (drag-and-drop)
-- ============================================

local function sendSlotUpdate(slotIndex, itemData)
	if not UpdateChestSlot or not currentChestBlock then return end
	UpdateChestSlot:FireServer(currentChestBlock, slotIndex, itemData)
end

local function onChestSlotClick(slotIndex)
	local inv = getInvController()
	if not inv then return end
	
	local isHolding = inv.IsHolding and inv.IsHolding()
	local existingItem = chestSlots[slotIndex]
	
	if isHolding then
		-- Drop held item into this chest slot
		local heldItem = inv.GetHeldItem()
		if not heldItem then return end
		
		-- Convert color to saveable format
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
			-- Swap: place held into slot, pick up existing
			chestSlots[slotIndex] = newItem
			updateSlotViewport(slotIndex)
			sendSlotUpdate(slotIndex, newItem)
			
			-- Discard current held item and pick up the existing one
			local existColor = nil
			if existingItem.c and type(existingItem.c) == "table" then
				existColor = Color3.fromRGB(existingItem.c[1] or 255, existingItem.c[2] or 255, existingItem.c[3] or 255)
			else
				local existPreset = BlockPresets.GetPreset(existingItem.p)
				if existPreset then existColor = existPreset.Color end
			end
			
			inv.DiscardHeld()
			pickedFromChestSlot = slotIndex
			inv.PickUpItem(existingItem.p, existColor, nil, existingItem.n or 1)
		else
			-- Empty slot: just place the held item
			chestSlots[slotIndex] = newItem
			updateSlotViewport(slotIndex)
			sendSlotUpdate(slotIndex, newItem)
			
			-- Clear chest source tracking since item was placed
			pickedFromChestSlot = nil
			
			-- Discard the held item (it's been placed)
			inv.DiscardHeld()
		end
		
		-- Flash feedback on the slot
		local slotFrame = chestSlotFrames[slotIndex]
		if slotFrame then
			local original = slotFrame.BackgroundColor3
			slotFrame.BackgroundColor3 = Colors.Success
			task.delay(0.15, function()
				TweenService:Create(slotFrame, TweenInfo.new(0.2), {BackgroundColor3 = original}):Play()
			end)
		end
	else
		-- Not holding anything: pick up from this chest slot
		if existingItem and existingItem.p then
			local color = nil
			if existingItem.c and type(existingItem.c) == "table" then
				color = Color3.fromRGB(existingItem.c[1] or 255, existingItem.c[2] or 255, existingItem.c[3] or 255)
			else
				local preset = BlockPresets.GetPreset(existingItem.p)
				if preset then color = preset.Color end
			end
			
			-- Remember which chest slot this came from
			pickedFromChestSlot = slotIndex
			
			-- Clear the chest slot
			chestSlots[slotIndex] = nil
			updateSlotViewport(slotIndex)
			sendSlotUpdate(slotIndex, nil)
			
			-- Pick up with InventoryController (nil sourceSlot = not from hotbar)
			inv.PickUpItem(existingItem.p, color, nil, existingItem.n or 1)
		end
	end
end

local function onChestSlotRightClick(slotIndex)
	-- Right-click clears a chest slot (puts item back to creative void)
	local existingItem = chestSlots[slotIndex]
	if existingItem and existingItem.p then
		chestSlots[slotIndex] = nil
		updateSlotViewport(slotIndex)
		sendSlotUpdate(slotIndex, nil)
	end
end

local function quickTransferIntoChest(item)
	if not isOpen or not item or not item.p then return false end
	
	for i = 1, totalSlots do
		if not chestSlots[i] or not chestSlots[i].p then
			chestSlots[i] = { p = item.p, c = item.c, n = item.n }
			updateSlotViewport(i)
			sendSlotUpdate(i, chestSlots[i])
			
			local slotFrame = chestSlotFrames[i]
			if slotFrame then
				local original = slotFrame.BackgroundColor3
				slotFrame.BackgroundColor3 = Colors.Success
				task.delay(0.15, function()
					TweenService:Create(slotFrame, TweenInfo.new(0.2), {BackgroundColor3 = original}):Play()
				end)
			end
			return true
		end
	end
	return false -- All full
end

-- ============================================
-- PERSONAL INVENTORY SLOTS (embedded below chest grid)
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
			-- Swap
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
			pickedFromChestSlot = nil
			inv.PickUpItem(existingItem.p, existColor, nil, existingItem.n or 1)
		else
			-- Place into empty slot
			inv.SetSurvivalSlot(slotIndex, newItem)
			updatePersonalSlotViewport(slotIndex)
			pickedFromChestSlot = nil
			inv.DiscardHeld()
		end
		
		-- Flash
		local sf = personalSlotFrames[slotIndex]
		if sf then
			local orig = sf.BackgroundColor3
			sf.BackgroundColor3 = Colors.Success
			task.delay(0.15, function()
				TweenService:Create(sf, TweenInfo.new(0.2), {BackgroundColor3 = orig}):Play()
			end)
		end
	else
		-- Pick up from personal inventory
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
			pickedFromChestSlot = nil
			inv.PickUpItem(existingItem.p, color, nil, existingItem.n or 1)
		end
	end
end

-- ============================================
-- HOTBAR ROW (embedded below personal inventory)
-- Reads/writes via InventoryController hotbar API. Lives inside the chest panel
-- so the player can move items between chest, personal inventory, and hotbar
-- while the on-screen hotbar bar is hidden.
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
	if not data then
		if countLabel then countLabel.Visible = false end
		return
	end
	
	-- Tool slots: handled by live hotbar UI, skip rendering here (chest panel
	-- treats them as opaque "don't touch" slots). Player can still click to move.
	if data.isTool then
		if countLabel then countLabel.Visible = false end
		return
	end
	
	if not data.p then
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
		
		-- Don't allow placing items onto tool slots
		if existingItem and existingItem.isTool then return end
		
		if existingItem and existingItem.p then
			-- Swap: place held into slot, pick up existing
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
			pickedFromChestSlot = nil
			inv.PickUpItem(existingItem.p, existColor, nil, existingItem.n or 1)
		else
			-- Place into empty hotbar slot
			inv.SetHotbarSlot(slotIndex, newItem)
			updateHotbarSlotViewport(slotIndex)
			pickedFromChestSlot = nil
			inv.DiscardHeld()
		end
		
		-- Flash
		local sf = hotbarSlotFrames[slotIndex]
		if sf then
			local orig = sf.BackgroundColor3
			sf.BackgroundColor3 = Colors.Success
			task.delay(0.15, function()
				TweenService:Create(sf, TweenInfo.new(0.2), {BackgroundColor3 = orig}):Play()
			end)
		end
	else
		-- Pick up from hotbar slot (skip tool slots)
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
			pickedFromChestSlot = nil
			inv.PickUpItem(existingItem.p, color, nil, existingItem.n or 1)
		end
	end
end

-- ============================================
-- SLOT CREATION
-- ============================================
local function createSlot(parent, row, col, slotIndex, zIndex)
	local slot = Instance.new("TextButton")
	slot.Name = "Slot_" .. slotIndex
	slot.Size = UDim2.new(0, SLOT_SIZE, 0, SLOT_SIZE)
	slot.Position = UDim2.new(0, col * (SLOT_SIZE + SLOT_PADDING), 0, row * (SLOT_SIZE + SLOT_PADDING))
	slot.BackgroundColor3 = Colors.CellBg
	slot.BorderSizePixel = 0
	slot.Text = ""
	slot.AutoButtonColor = false
	slot.ZIndex = zIndex or 3
	slot.Parent = parent

	addInsetBevel(slot)
	
	-- Stack count label (bottom-right, Minecraft style)
	local chestCountLabel = Instance.new("TextLabel")
	chestCountLabel.Name = "CountLabel"
	chestCountLabel.Size = UDim2.new(0, 24, 0, 16)
	chestCountLabel.Position = UDim2.new(1, -26, 1, -18)
	chestCountLabel.BackgroundTransparency = 1
	chestCountLabel.Text = ""
	chestCountLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	chestCountLabel.TextSize = 13
	chestCountLabel.Font = Enum.Font.GothamBold
	chestCountLabel.TextXAlignment = Enum.TextXAlignment.Right
	chestCountLabel.ZIndex = 6
	chestCountLabel.Visible = false
	chestCountLabel.Parent = slot
	
	local chestCountStroke = Instance.new("UIStroke")
	chestCountStroke.Color = Color3.fromRGB(30, 30, 30)
	chestCountStroke.Thickness = 1.5
	chestCountStroke.Parent = chestCountLabel

	slot.MouseEnter:Connect(function()
		slot.BackgroundColor3 = Colors.CellHover
	end)
	slot.MouseLeave:Connect(function()
		slot.BackgroundColor3 = Colors.CellBg
	end)
	
	-- Mobile detection
	local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	
	-- Long-press tracking for mobile drag pickup
	local chestPressStart = nil
	local chestLongPressFired = false
	local CHEST_LONG_PRESS_TIME = 0.35
	
	slot.MouseButton1Down:Connect(function()
		chestPressStart = tick()
		chestLongPressFired = false
		
		local inv = getInvController()
		if isMobile and inv and not (inv.IsHolding and inv.IsHolding()) then
			-- Start long-press timer for mobile pickup from chest
			local startTime = chestPressStart
			task.delay(CHEST_LONG_PRESS_TIME, function()
				if chestPressStart == startTime and not chestLongPressFired and isOpen then
					chestLongPressFired = true
					local existingItem = chestSlots[slotIndex]
					if existingItem and existingItem.p then
						onChestSlotClick(slotIndex) -- pick up
					end
				end
			end)
		end
	end)
	
	slot.MouseButton1Up:Connect(function()
		chestPressStart = nil
	end)
	
	-- Left click: drag-and-drop
	slot.MouseButton1Click:Connect(function()
		if not isOpen then return end
		if chestLongPressFired then return end -- Already handled by long-press
		
		local inv = getInvController()
		if isMobile and inv and not (inv.IsHolding and inv.IsHolding()) then
			-- Mobile tap without holding: do nothing (need long-press to pick up)
			return
		end
		
		-- Shift-click: quick-transfer to personal inventory (fallback to hotbar)
		if not isMobile and inv then
			local isShift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			if isShift and not (inv.IsHolding and inv.IsHolding()) then
				local item = chestSlots[slotIndex]
				if item and item.p then
					local transferred = false
					-- Try personal inventory first
					if inv.QuickTransferToSurvival then
						transferred = inv.QuickTransferToSurvival(item)
						if transferred then renderAllPersonalSlots() end
					end
					-- Fallback to hotbar
					if not transferred and inv.QuickTransferToHotbar then
						transferred = inv.QuickTransferToHotbar(item)
					end
					if transferred then
						chestSlots[slotIndex] = nil
						updateSlotViewport(slotIndex)
						sendSlotUpdate(slotIndex, nil)
					end
				end
				return
			end
		end
		
		onChestSlotClick(slotIndex)
	end)
	
	-- Right click: clear slot (desktop only)
	slot.MouseButton2Click:Connect(function()
		if isOpen then
			onChestSlotRightClick(slotIndex)
		end
	end)

	chestSlotFrames[slotIndex] = slot
	return slot
end

-- ============================================
-- BUILD UI
-- ============================================
local function buildUI()
	if screenGui then screenGui:Destroy() end

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ChestUI"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 15
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	-- Transparent click-catcher (closes UI when clicking outside)
	local overlay = Instance.new("TextButton")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundTransparency = 1
	overlay.BorderSizePixel = 0
	overlay.Text = ""
	overlay.ZIndex = 1
	overlay.Parent = screenGui

	overlay.MouseButton1Click:Connect(function()
		if isOpen then
			_G.ChestUI.Close()
		end
	end)

	-- Main panel (sized dynamically in Open)
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

local function populateSlots(rows, blockColor)
	-- Clear existing children except bevels
	for _, child in mainFrame:GetChildren() do
		if not child.Name:match("^Bevel") then
			child:Destroy()
		end
	end
	
	-- Clear slot frame references
	chestSlotFrames = {}
	personalSlotFrames = {}
	hotbarSlotFrames = {}
	
	-- Recompute slot size from current viewport (handles rotation, late-init)
	SLOT_SIZE = computeSlotSize()
	
	-- Color theming: darken the wood color for UI background
	local bgColor = Colors.Background
	local gridBgColor = Colors.Background
	if blockColor then
		bgColor = darkenColor(blockColor, 0.15)
		gridBgColor = darkenColor(blockColor, 0.12)
	end
	mainFrame.BackgroundColor3 = bgColor

	local gridWidth = COLS * (SLOT_SIZE + SLOT_PADDING) - SLOT_PADDING
	local gridHeight = rows * (SLOT_SIZE + SLOT_PADDING) - SLOT_PADDING
	local panelPadding = 16
	local titleHeight = 32
	local closeBtnSize = 28
	local separatorGap = 8
	local invLabelHeight = 24
	
	-- Personal inventory sizing
	local inv = getInvController()
	local personalRows = inv and inv.GetSurvivalRows and inv.GetSurvivalRows() or 5
	local personalSlotCount = inv and inv.GetSurvivalSlotCount and inv.GetSurvivalSlotCount() or 45
	local personalGridHeight = personalRows * (SLOT_SIZE + SLOT_PADDING) - SLOT_PADDING
	
	-- Hotbar sizing: 10 slots packed into the same WIDTH as the 9-slot personal
	-- inventory above (so the hotbar row aligns visually with the inventory).
	-- That means each hotbar slot is slightly smaller than an inventory slot.
	local hotbarSlotW = math.max(20, math.floor((gridWidth - (HOTBAR_COLS - 1) * SLOT_PADDING) / HOTBAR_COLS))
	local hotbarRowHeight = SLOT_SIZE
	local hotbarGap = 8 -- vertical gap between personal inventory grid and hotbar row
	local hotbarContainerHeight = hotbarRowHeight + 12 -- +12 for inset bevel padding

	local panelWidth, panelHeight
	if SideBySide then
		-- Side-by-side: chest on left, personal + hotbar stacked on right
		local gridGap = 16
		local rightColumnHeight = (personalGridHeight + 12) + hotbarGap + hotbarContainerHeight
		local leftColumnHeight = gridHeight + 12
		local maxColHeight = math.max(leftColumnHeight, rightColumnHeight)
		panelWidth = panelPadding * 2 + (gridWidth + 12) * 2 + gridGap
		panelHeight = titleHeight + 6 + maxColHeight + panelPadding
	else
		panelWidth = gridWidth + panelPadding * 2
		panelHeight = titleHeight + 6 + (gridHeight + 12) + separatorGap + invLabelHeight
			+ (personalGridHeight + 12) + hotbarGap + hotbarContainerHeight + panelPadding
	end
	mainFrame.Size = UDim2.new(0, panelWidth, 0, panelHeight)

	-- Title
	local titleText = (rows == DOUBLE_ROWS) and "Large Chest" or "Chest"
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, -panelPadding * 2 - closeBtnSize - 8, 0, titleHeight)
	title.Position = UDim2.new(0, panelPadding, 0, 6)
	title.BackgroundTransparency = 1
	title.Text = titleText
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
		if isOpen then _G.ChestUI.Close() end
	end)

	-- ======== CHEST GRID ========
	local chestGridY = titleHeight + 6
	local gridContainer = Instance.new("Frame")
	gridContainer.Name = "GridContainer"
	gridContainer.Size = UDim2.new(0, gridWidth + 12, 0, gridHeight + 12)
	gridContainer.Position = UDim2.new(0, panelPadding - 6, 0, chestGridY)
	gridContainer.BackgroundColor3 = gridBgColor
	gridContainer.BorderSizePixel = 0
	gridContainer.ZIndex = 2
	gridContainer.Parent = mainFrame
	addInsetBevel(gridContainer)

	local slotContainer = Instance.new("Frame")
	slotContainer.Name = "Slots"
	slotContainer.Size = UDim2.new(0, gridWidth, 0, gridHeight)
	slotContainer.Position = UDim2.new(0, 6, 0, 6)
	slotContainer.BackgroundTransparency = 1
	slotContainer.ZIndex = 3
	slotContainer.Parent = gridContainer

	for row = 0, rows - 1 do
		for col = 0, COLS - 1 do
			local slotIndex = row * COLS + col + 1
			createSlot(slotContainer, row, col, slotIndex, 3)
		end
	end
	
	-- ======== PERSONAL INVENTORY GRID ========
	-- Layout-dependent positioning:
	--   Side-by-side: personal grid sits to the right of the chest grid at the same Y.
	--   Stacked: separator + label + personal below chest grid.
	local personalContainerX, personalContainerY
	
	if SideBySide then
		-- No separator/label; personal sits to the right at same Y
		personalContainerX = panelPadding - 6 + (gridWidth + 12) + 16 -- +gap of 16
		personalContainerY = chestGridY
	else
		-- Separator + inventory label between the two grids
		local separatorY = chestGridY + gridHeight + 12 + separatorGap
		
		local sepLine = Instance.new("Frame")
		sepLine.Name = "Separator"
		sepLine.Size = UDim2.new(0, gridWidth, 0, 1)
		sepLine.Position = UDim2.new(0, panelPadding, 0, separatorY - 4)
		sepLine.BackgroundColor3 = Colors.BorderHighlight
		sepLine.BackgroundTransparency = 0.5
		sepLine.BorderSizePixel = 0
		sepLine.ZIndex = 3
		sepLine.Parent = mainFrame
		
		local invLabel = Instance.new("TextLabel")
		invLabel.Name = "InventoryLabel"
		invLabel.Size = UDim2.new(0, gridWidth, 0, invLabelHeight)
		invLabel.Position = UDim2.new(0, panelPadding, 0, separatorY)
		invLabel.BackgroundTransparency = 1
		invLabel.Text = "Inventory"
		invLabel.TextColor3 = Colors.Text
		invLabel.TextSize = 14
		invLabel.Font = FONT
		invLabel.TextXAlignment = Enum.TextXAlignment.Left
		invLabel.ZIndex = 3
		invLabel.Parent = mainFrame
		
		personalContainerX = panelPadding - 6
		personalContainerY = separatorY + invLabelHeight
	end
	
	local personalContainer = Instance.new("Frame")
	personalContainer.Name = "PersonalContainer"
	personalContainer.Size = UDim2.new(0, gridWidth + 12, 0, personalGridHeight + 12)
	personalContainer.Position = UDim2.new(0, personalContainerX, 0, personalContainerY)
	personalContainer.BackgroundColor3 = gridBgColor
	personalContainer.BorderSizePixel = 0
	personalContainer.ZIndex = 2
	personalContainer.Parent = mainFrame
	addInsetBevel(personalContainer)
	
	local personalSlotContainer = Instance.new("Frame")
	personalSlotContainer.Name = "PersonalSlots"
	personalSlotContainer.Size = UDim2.new(0, gridWidth, 0, personalGridHeight)
	personalSlotContainer.Position = UDim2.new(0, 6, 0, 6)
	personalSlotContainer.BackgroundTransparency = 1
	personalSlotContainer.ZIndex = 3
	personalSlotContainer.Parent = personalContainer
	
	local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	
	for row = 0, personalRows - 1 do
		for col = 0, PERSONAL_COLS - 1 do
			local slotIndex = row * PERSONAL_COLS + col + 1
			
			local pSlot = Instance.new("TextButton")
			pSlot.Name = "PSlot_" .. slotIndex
			pSlot.Size = UDim2.new(0, SLOT_SIZE, 0, SLOT_SIZE)
			pSlot.Position = UDim2.new(0, col * (SLOT_SIZE + SLOT_PADDING), 0, row * (SLOT_SIZE + SLOT_PADDING))
			pSlot.BackgroundColor3 = Colors.CellBg
			pSlot.BorderSizePixel = 0
			pSlot.Text = ""
			pSlot.AutoButtonColor = false
			pSlot.ZIndex = 3
			pSlot.Parent = personalSlotContainer
			
			addInsetBevel(pSlot)
			
			-- Count label
			local pCount = Instance.new("TextLabel")
			pCount.Name = "CountLabel"
			pCount.Size = UDim2.new(0, 24, 0, 16)
			pCount.Position = UDim2.new(1, -26, 1, -18)
			pCount.BackgroundTransparency = 1
			pCount.Text = ""
			pCount.TextColor3 = Color3.fromRGB(255, 255, 255)
			pCount.TextSize = 13
			pCount.Font = Enum.Font.GothamBold
			pCount.TextXAlignment = Enum.TextXAlignment.Right
			pCount.ZIndex = 6
			pCount.Visible = false
			pCount.Parent = pSlot
			local pCountStroke = Instance.new("UIStroke")
			pCountStroke.Color = Color3.fromRGB(30, 30, 30)
			pCountStroke.Thickness = 1.5
			pCountStroke.Parent = pCount
			
			pSlot.MouseEnter:Connect(function() pSlot.BackgroundColor3 = Colors.CellHover end)
			pSlot.MouseLeave:Connect(function() pSlot.BackgroundColor3 = Colors.CellBg end)
			
			-- Long-press for mobile
			local pPressStart, pLongFired = nil, false
			
			pSlot.MouseButton1Down:Connect(function()
				pPressStart = tick(); pLongFired = false
				if isMobile and not (inv and inv.IsHolding and inv.IsHolding()) then
					local st = pPressStart
					task.delay(0.35, function()
						if pPressStart == st and not pLongFired and isOpen then
							pLongFired = true
							local survSlots = inv and inv.GetSurvivalSlots() or {}
							if survSlots[slotIndex] and survSlots[slotIndex].p then
								onPersonalSlotClick(slotIndex)
							end
						end
					end)
				end
			end)
			pSlot.MouseButton1Up:Connect(function() pPressStart = nil end)
			
			pSlot.MouseButton1Click:Connect(function()
				if pLongFired then return end
				if isMobile and inv and not (inv.IsHolding and inv.IsHolding()) then return end
				
				-- Shift-click: quick-transfer to chest
				if not isMobile and inv then
					local isShift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
					if isShift and not (inv.IsHolding and inv.IsHolding()) then
						local survSlots = inv.GetSurvivalSlots()
						local item = survSlots[slotIndex]
						if item and item.p then
							if quickTransferIntoChest(item) then
								inv.SetSurvivalSlot(slotIndex, nil)
								updatePersonalSlotViewport(slotIndex)
							end
						end
						return
					end
				end
				
				onPersonalSlotClick(slotIndex)
			end)
			
			pSlot.MouseButton2Click:Connect(function()
				-- Right-click: clear personal slot
				if inv then
					inv.SetSurvivalSlot(slotIndex, nil)
					updatePersonalSlotViewport(slotIndex)
				end
			end)
			
			personalSlotFrames[slotIndex] = pSlot
		end
	end
	
	-- ======== HOTBAR ROW ========
	-- Sits directly below the personal inventory in both layouts. Same X as the
	-- personal inventory container so the rows align visually.
	local hotbarContainerY = personalContainerY + personalGridHeight + 12 + hotbarGap
	
	local hotbarContainer = Instance.new("Frame")
	hotbarContainer.Name = "HotbarContainer"
	hotbarContainer.Size = UDim2.new(0, gridWidth + 12, 0, hotbarContainerHeight)
	hotbarContainer.Position = UDim2.new(0, personalContainerX, 0, hotbarContainerY)
	hotbarContainer.BackgroundColor3 = gridBgColor
	hotbarContainer.BorderSizePixel = 0
	hotbarContainer.ZIndex = 2
	hotbarContainer.Parent = mainFrame
	addInsetBevel(hotbarContainer)
	
	local hotbarSlotContainer = Instance.new("Frame")
	hotbarSlotContainer.Name = "HotbarSlots"
	hotbarSlotContainer.Size = UDim2.new(0, gridWidth, 0, hotbarRowHeight)
	hotbarSlotContainer.Position = UDim2.new(0, 6, 0, 6)
	hotbarSlotContainer.BackgroundTransparency = 1
	hotbarSlotContainer.ZIndex = 3
	hotbarSlotContainer.Parent = hotbarContainer
	
	for col = 0, HOTBAR_COLS - 1 do
		local slotIndex = col + 1
		
		local hSlot = Instance.new("TextButton")
		hSlot.Name = "HSlot_" .. slotIndex
		hSlot.Size = UDim2.new(0, hotbarSlotW, 0, hotbarRowHeight)
		hSlot.Position = UDim2.new(0, col * (hotbarSlotW + SLOT_PADDING), 0, 0)
		hSlot.BackgroundColor3 = Colors.CellBg
		hSlot.BorderSizePixel = 0
		hSlot.Text = ""
		hSlot.AutoButtonColor = false
		hSlot.ZIndex = 3
		hSlot.Parent = hotbarSlotContainer
		
		addInsetBevel(hSlot)
		
		-- Slot number label (1-9, 0 for slot 10) - desktop only, mobile saves space
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
		numLabel.Visible = not isMobile
		numLabel.Parent = hSlot
		
		-- Count label
		local hCount = Instance.new("TextLabel")
		hCount.Name = "CountLabel"
		hCount.Size = UDim2.new(0, 24, 0, 16)
		hCount.Position = UDim2.new(1, -26, 1, -18)
		hCount.BackgroundTransparency = 1
		hCount.Text = ""
		hCount.TextColor3 = Color3.fromRGB(255, 255, 255)
		hCount.TextSize = 13
		hCount.Font = Enum.Font.GothamBold
		hCount.TextXAlignment = Enum.TextXAlignment.Right
		hCount.ZIndex = 6
		hCount.Visible = false
		hCount.Parent = hSlot
		local hCountStroke = Instance.new("UIStroke")
		hCountStroke.Color = Color3.fromRGB(30, 30, 30)
		hCountStroke.Thickness = 1.5
		hCountStroke.Parent = hCount
		
		hSlot.MouseEnter:Connect(function() hSlot.BackgroundColor3 = Colors.CellHover end)
		hSlot.MouseLeave:Connect(function() hSlot.BackgroundColor3 = Colors.CellBg end)
		
		-- Long-press for mobile
		local hPressStart, hLongFired = nil, false
		
		hSlot.MouseButton1Down:Connect(function()
			hPressStart = tick(); hLongFired = false
			if isMobile and not (inv and inv.IsHolding and inv.IsHolding()) then
				local st = hPressStart
				task.delay(0.35, function()
					if hPressStart == st and not hLongFired and isOpen then
						hLongFired = true
						local item = inv and inv.GetHotbarSlot(slotIndex)
						if item and item.p and not item.isTool then
							onHotbarSlotClick(slotIndex)
						end
					end
				end)
			end
		end)
		hSlot.MouseButton1Up:Connect(function() hPressStart = nil end)
		
		hSlot.MouseButton1Click:Connect(function()
			if hLongFired then return end
			if isMobile and inv and not (inv.IsHolding and inv.IsHolding()) then return end
			
			-- Shift-click: quick-transfer to chest
			if not isMobile and inv then
				local isShift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
				if isShift and not (inv.IsHolding and inv.IsHolding()) then
					local item = inv.GetHotbarSlot(slotIndex)
					if item and item.p and not item.isTool then
						if quickTransferIntoChest(item) then
							inv.SetHotbarSlot(slotIndex, nil)
							updateHotbarSlotViewport(slotIndex)
						end
					end
					return
				end
			end
			
			onHotbarSlotClick(slotIndex)
		end)
		
		hSlot.MouseButton2Click:Connect(function()
			-- Right-click: clear hotbar slot (skip tool slots)
			if inv then
				local item = inv.GetHotbarSlot(slotIndex)
				if item and not item.isTool then
					inv.SetHotbarSlot(slotIndex, nil)
					updateHotbarSlotViewport(slotIndex)
				end
			end
		end)
		
		hotbarSlotFrames[slotIndex] = hSlot
	end
end

-- ============================================
-- RENDER CHEST CONTENTS (after server responds)
-- ============================================
local function renderAllSlots()
	for i = 1, totalSlots do
		updateSlotViewport(i)
	end
end

-- ============================================
-- OPEN / CLOSE
-- ============================================
local function openUI(chestBlock)
	if isOpen then return end
	isOpen = true
	currentChestBlock = chestBlock
	pickedFromChestSlot = nil

	-- Determine single vs double chest
	local isDouble = chestBlock and chestBlock:GetAttribute("IsDoubleChest") == true
	local rows = isDouble and DOUBLE_ROWS or SINGLE_ROWS
	totalSlots = rows * COLS

	-- Reset slot data
	chestSlots = {}
	
	-- Get wood color for UI theming
	local blockColor = getBlockUIColor(chestBlock)

	populateSlots(rows, blockColor)
	screenGui.Enabled = true

	-- Background blur
	local blur = Lighting:FindFirstChild("ChestUIBlur")
	if not blur then
		blur = Instance.new("BlurEffect")
		blur.Name = "ChestUIBlur"
		blur.Parent = Lighting
	end
	blur.Size = 12

	-- Request chest contents from server
	if RequestChestContents and chestBlock then
		RequestChestContents:FireServer(chestBlock)
	end
	
	-- Request personal inventory data and render when ready
	local inv = getInvController()
	if inv then
		if inv.IsSurvivalLoaded and inv.IsSurvivalLoaded() then
			renderAllPersonalSlots()
		else
			if inv.RequestSurvivalData then inv.RequestSurvivalData() end
		end
		-- Render hotbar slots from current live state
		renderAllHotbarSlots()
		-- Hide the on-screen hotbar (and toolbelt) while the chest panel is open
		-- so the embedded hotbar row inside the panel is the only one visible.
		if inv.SetHotbarVisible then inv.SetHotbarVisible(false) end
	end
end

local function closeUI()
	if not isOpen then return end
	isOpen = false
	local closedBlock = currentChestBlock
	currentChestBlock = nil

	-- If player is holding an item picked up from this chest, return it
	local inv = getInvController()
	if inv and inv.IsHolding and inv.IsHolding() and pickedFromChestSlot then
		local heldItem = inv.GetHeldItem()
		if heldItem and closedBlock then
			-- Return item to the chest slot it came from
			local colorArray = nil
			if heldItem.Color then
				colorArray = {
					math.floor(heldItem.Color.R * 255 + 0.5),
					math.floor(heldItem.Color.G * 255 + 0.5),
					math.floor(heldItem.Color.B * 255 + 0.5),
				}
			end
			local returnItem = { p = heldItem.PresetId, c = colorArray, n = heldItem.Count or 1 }
			chestSlots[pickedFromChestSlot] = returnItem
			if UpdateChestSlot then
				UpdateChestSlot:FireServer(closedBlock, pickedFromChestSlot, returnItem)
			end
		end
		inv.DiscardHeld()
	elseif inv and inv.IsHolding and inv.IsHolding() then
		-- Holding an item from hotbar/creative — cancel it (return to source)
		if inv.CancelHeldItem then
			inv.CancelHeldItem()
		end
	end
	
	pickedFromChestSlot = nil
	screenGui.Enabled = false

	-- Remove blur
	local blur = Lighting:FindFirstChild("ChestUIBlur")
	if blur then
		blur.Size = 0
	end
	
	-- Restore the on-screen hotbar now that the chest panel is closed
	if inv and inv.SetHotbarVisible then inv.SetHotbarVisible(true) end

	-- Notify BlockInteractionController so InventoryController doesn't open on same frame
	if _G.BlockInteractionController and _G.BlockInteractionController.NotifyClosed then
		_G.BlockInteractionController.NotifyClosed()
	end

	if onCloseCallback then
		task.defer(onCloseCallback, closedBlock)
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
-- REMOTES
-- ============================================
task.spawn(function()
	RequestChestContents = Remotes:WaitForChild("RequestChestContents", 10)
	ChestContentsResponse = Remotes:WaitForChild("ChestContentsResponse", 10)
	UpdateChestSlot = Remotes:WaitForChild("UpdateChestSlot", 10)
	
	if ChestContentsResponse then
		ChestContentsResponse.OnClientEvent:Connect(function(chestBlock, contents)
			-- Only process if this response is for the currently open chest
			if not isOpen or chestBlock ~= currentChestBlock then return end
			if not contents or type(contents) ~= "table" then return end
			
			-- Load contents into local slot data
			for i = 1, totalSlots do
				local item = contents[i]
				if item and type(item) == "table" and item.p then
					chestSlots[i] = item
				else
					chestSlots[i] = nil
				end
			end
			
			-- Render viewport previews
			renderAllSlots()
			print("[ChestUI] Received contents for chest, rendering slots")
		end)
	end
end)

-- ============================================
-- INIT
-- ============================================
buildUI()

_G.ChestUI = {
	IsOpen = function() return isOpen end,
	Open = function(chestBlock) openUI(chestBlock) end,
	Close = function() closeUI() end,
	GetCurrentBlock = function() return currentChestBlock end,
	SetOnClose = function(callback) onCloseCallback = callback end,
	QuickTransferIn = quickTransferIntoChest,
}

-- Register callback for when survival data loads (refresh personal inventory slots)
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

print("[ChestUI] Initialized (functional drag-and-drop chest inventory)")
