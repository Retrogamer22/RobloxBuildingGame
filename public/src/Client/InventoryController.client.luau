--[[
	InventoryController
	Simplified inventory with presets and hotbar
	Categories use square viewport buttons with block icons
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))
local GlassPlacement = require(ReplicatedStorage:WaitForChild("GlassPlacement", 10))
local PaintCanVisual = require(ReplicatedStorage:WaitForChild("PaintCanVisual", 10)) -- Paint Mod
local UITheme = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("UITheme"))
local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))
local BlockTemplates = ReplicatedStorage:WaitForChild("BlockTemplates", 10)
local BlocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)
local DecorationsFolder = ReplicatedStorage:WaitForChild("Decorations", 10)
local ToolsFolder = ReplicatedStorage:FindFirstChild("Tools")
local FrameBlocksFolder = ReplicatedStorage:FindFirstChild("FrameBlocks")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera

-- Mobile detection
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- ============================================
-- DARK MODE COLOR THEME
-- ============================================
local Colors = {
	Background = Color3.fromRGB(30, 30, 30),          -- Dark panel bg
	Surface = Color3.fromRGB(40, 40, 40),             -- Header/tabs surface
	SurfaceHover = Color3.fromRGB(55, 55, 55),        -- Lighter hover
	SurfaceActive = Color3.fromRGB(60, 60, 65),       -- Pressed/active
	Accent = Color3.fromRGB(76, 175, 80),              -- MC green (kept)
	Text = Color3.fromRGB(220, 220, 220),              -- Light text on dark bg
	TextMuted = Color3.fromRGB(140, 140, 140),         -- Muted text on dark bg
	Border = Color3.fromRGB(10, 10, 10),               -- Near-black borders
	BorderHighlight = Color3.fromRGB(70, 70, 70),      -- Subtle bevel highlight
	Success = Color3.fromRGB(76, 175, 80),
	Danger = Color3.fromRGB(220, 53, 53),
	SlotBg = Color3.fromRGB(50, 50, 50),               -- Dark slot bg
	SlotBgSelected = Color3.fromRGB(60, 60, 80),       -- Blue-ish highlight on dark
	HotbarBg = Color3.fromRGB(25, 25, 25),             -- Dark hotbar bg
	Selected = Color3.fromRGB(255, 255, 255),
	CellBg = Color3.fromRGB(50, 50, 50),               -- Dark cell bg
	CellHover = Color3.fromRGB(70, 70, 90),            -- Blue-ish hover on dark
	CellText = Color3.fromRGB(255, 255, 255),          -- White text on cells
}

-- ============================================
-- MINECRAFT BEVEL HELPER
-- Creates the classic MC raised/sunken 3D edge effect
-- ============================================
local BEVEL_SIZE = 3 -- Thickness of bevel edges in pixels

-- Add raised bevel (top/left = light, bottom/right = dark) for buttons/panels
local function addBevel(frame, highlightColor, shadowColor)
	local hl = highlightColor or Color3.fromRGB(80, 80, 80)
	local sh = shadowColor or Color3.fromRGB(0, 0, 0)
	local hlAlpha = 0.3 -- Transparency for highlights
	local shAlpha = 0.3 -- Transparency for shadows
	
	-- Top highlight
	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = hl
	top.BackgroundTransparency = hlAlpha
	top.BorderSizePixel = 0
	top.ZIndex = 5
	top.Parent = frame
	
	-- Left highlight
	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = hl
	left.BackgroundTransparency = hlAlpha
	left.BorderSizePixel = 0
	left.ZIndex = 5
	left.Parent = frame
	
	-- Bottom shadow
	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL_SIZE)
	bottom.BackgroundColor3 = sh
	bottom.BackgroundTransparency = shAlpha
	bottom.BorderSizePixel = 0
	bottom.ZIndex = 5
	bottom.Parent = frame
	
	-- Right shadow
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

-- Add sunken/inset bevel (top/left = dark, bottom/right = light) for slots/inputs
-- MC inventory slots have very strong inset: dark top/left, bright white bottom/right
local function addInsetBevel(frame, shadowColor, highlightColor)
	local sh = shadowColor or Color3.fromRGB(10, 10, 10)
	local hl = highlightColor or Color3.fromRGB(70, 70, 70)
	local shAlpha = 0.0  -- Fully opaque dark edges
	local hlAlpha = 0.0  -- Fully opaque light edges
	
	-- Top shadow (inset = dark on top)
	local top = Instance.new("Frame")
	top.Name = "BevelTop"
	top.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	top.Position = UDim2.new(0, 0, 0, 0)
	top.BackgroundColor3 = sh
	top.BackgroundTransparency = shAlpha
	top.BorderSizePixel = 0
	top.ZIndex = 5
	top.Parent = frame
	
	-- Left shadow
	local left = Instance.new("Frame")
	left.Name = "BevelLeft"
	left.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	left.Position = UDim2.new(0, 0, 0, 0)
	left.BackgroundColor3 = sh
	left.BackgroundTransparency = shAlpha
	left.BorderSizePixel = 0
	left.ZIndex = 5
	left.Parent = frame
	
	-- Bottom highlight (inset = light on bottom)
	local bottom = Instance.new("Frame")
	bottom.Name = "BevelBottom"
	bottom.Size = UDim2.new(1, 0, 0, BEVEL_SIZE)
	bottom.Position = UDim2.new(0, 0, 1, -BEVEL_SIZE)
	bottom.BackgroundColor3 = hl
	bottom.BackgroundTransparency = hlAlpha
	bottom.BorderSizePixel = 0
	bottom.ZIndex = 5
	bottom.Parent = frame
	
	-- Right highlight
	local right = Instance.new("Frame")
	right.Name = "BevelRight"
	right.Size = UDim2.new(0, BEVEL_SIZE, 1, 0)
	right.Position = UDim2.new(1, -BEVEL_SIZE, 0, 0)
	right.BackgroundColor3 = hl
	right.BackgroundTransparency = hlAlpha
	right.BorderSizePixel = 0
	right.ZIndex = 5
	right.Parent = frame
end

-- Feature toggles (set to false to hide for future release)
local SHOW_TOOL_BELT = false -- Set to true when tool belt features are ready

-- State
local CurrentSlot = 1
local CurrentRotation = 0
local InventoryOpen = false
local SelectedCategory = "Building"
local IsToolSlotSelected = false -- Whether we're on tool belt vs main hotbar
local CurrentToolSlot = 1
local HoveredSurvivalSlot = nil -- Index of survival slot the cursor is hovering, used for Q-to-remove

-- Hotbar data: { PresetId, Color, Count }
local HOTBAR_SLOTS = 10
local MAX_STACK = 64
local Hotbar = {}
for i = 1, HOTBAR_SLOTS do
	Hotbar[i] = nil
end

-- Tool Belt data (3 dedicated tool slots)
local ToolBelt = {}
for i = 1, 3 do
	ToolBelt[i] = nil
end

-- Permanent tools that are pre-loaded and can't be removed
local PermanentTools = {
	[1] = "WireTool", -- Wiring tool always in slot 1
}

-- UI References
local ScreenGui, HotbarFrame, SlotFrames, SelectionFrame, BlockNameLabel
local InventoryPanel, PresetsContainer, CategoryButtons
local MobileButtonsFrame -- Mobile UI container
local ToolBeltFrame, ToolSlotFrames, ToolSelectionFrame -- Tool belt UI
local SearchBox -- Search input
local CurrentSearchQuery = "" -- Current search filter
local CategoryTooltip -- Shared tooltip frame for category/block buttons
local CategoryTooltipText -- Text label inside the tooltip
local ToolTooltip -- Shared tooltip for tool items
local RightTabButtons = {} -- Right side tab buttons (Tools, etc.)
local SelectedRightTab = nil -- Currently selected right tab (nil = showing blocks)

-- Personal inventory state (persistent personal inventory, 36 slots)
local SURVIVAL_SLOTS = 36
local SURVIVAL_COLS = 9
local SURVIVAL_ROWS = 4
local SurvivalSlots = {} -- [slotIndex] = {p, c, n} or nil
local SurvivalSlotFrames = {} -- [slotIndex] = TextButton
local SurvivalGridFrame = nil -- Container frame for the fixed grid
local SurvivalLoaded = false
local SurvivalRemotes = {} -- Populated in task.spawn at bottom
local SurvivalDataCallbacks = {} -- External callbacks when survival data loads/updates

-- ============================================
-- "NEW" BLOCK BADGE SYSTEM
-- Tracks which blocks are new (unseen) this session
-- Badges persist visually all session, clear on rejoin
-- ============================================
local NewBlockIds = {} -- { ["BlockId"] = true } — set of new block IDs for this session
local NewCategories = {} -- { ["CategoryName"] = true } — categories containing new blocks
local NewRightTabs = {} -- { ["TabName"] = true } — right tabs containing new blocks
local NewBlocksLoaded = false -- Whether we've fetched new block data from server
local MarkTabSeenRemote = nil -- RemoteEvent populated on init

-- DEBUG: Set to true to inject fake "new" blocks for visual testing in Studio
-- Picks a few blocks from multiple categories so you can see badges + tab dots
local DEBUG_NEW_BLOCKS = false

-- Map new block IDs to their categories/tabs so we know which tabs need "!" badges

-- Single source of truth: is this preset actually visible in the inventory grid
-- for THIS player right now? Mirrors the grid's own gating (HideFromInventory,
-- IsRainbow unlock, IsRewardBlock unlock) so the "!" badge system and the
-- mark-as-seen RPC never disagree with what the player can actually see.
--
-- Owner bypass uses BetaConfig.OWNER_USER_ID (NOT game.CreatorId) — this is a
-- group-owned game, so game.CreatorId returns the group id, not the user id.
local function getOwnerUserId()
	if BetaConfig.OWNER_USER_ID and BetaConfig.OWNER_USER_ID ~= 0 then
		return BetaConfig.OWNER_USER_ID
	end
	return game.CreatorId
end

local function isPresetVisible(preset)
	if preset.HideFromInventory then return false end
	local isOwner = (LocalPlayer.UserId == getOwnerUserId())
	-- Owner preview mode: pretend we're a fresh player so we can see what
	-- the inventory looks like before unlocks. Toggled via the /preview chat
	-- command (server-side BetaAdminCommands handler).
	local previewingAsFresh = isOwner and (LocalPlayer:GetAttribute("PreviewAsFresh") == true)
	local effectivelyOwner = isOwner and not previewingAsFresh
	if preset.IsRainbow and not effectivelyOwner then
		if not LocalPlayer:GetAttribute("RainbowBlocksUnlocked") then return false end
	end
	if preset.IsRewardBlock and not effectivelyOwner then
		-- Variants of the same base block (CandyCaneLog_Red, CandyCaneLog_Blue, ...)
		-- share an unlock under the BaseBlock name. Unlocking CandyCaneLog reveals
		-- ALL 17 colored variants. Non-variant rewards check by their own Id.
		local unlockKey = "Unlocked_" .. (preset.BaseBlock or preset.Id)
		if not LocalPlayer:GetAttribute(unlockKey) then return false end
	end
	return true
end

-- Should a themed-pack tab (e.g. "Candy") be visible to this player right now?
-- Visible if the player has unlocked at least one block from any set that maps
-- to this tab — OR if they're the owner (and not in /preview mode).
local function isTabVisible(tabName)
	local isOwner = (LocalPlayer.UserId == getOwnerUserId())
	local previewingAsFresh = isOwner and (LocalPlayer:GetAttribute("PreviewAsFresh") == true)
	if isOwner and not previewingAsFresh then return true end
	-- Non-owner (or owner-in-preview): visible only if at least one block in the
	-- tab is unlocked. Reuses isPresetVisible so the logic stays in one place.
	local presets = BlockPresets.GetPresetsByCategory(tabName)
	for _, preset in ipairs(presets) do
		if isPresetVisible(preset) then return true end
	end
	return false
end

local function computeNewCategoriesFromIds()
	NewCategories = {}
	NewRightTabs = {}
	
	if not next(NewBlockIds) then return end
	
	-- Check each new block ID against all presets to find its category
	local allPresets = BlockPresets.GetAllPresets()
	for _, preset in ipairs(allPresets) do
		if NewBlockIds[preset.Id] and isPresetVisible(preset) then
			local cat = preset.Category
			if cat then
				-- Frames is a right tab, not a left category
				if cat == "Frames" then
					NewRightTabs["Frames"] = true
				else
					NewCategories[cat] = true
				end
			end
		end
	end
end

-- Helper: add "NEW" badge to a block cell button (MC-style square with bevel)
local function addNewBadge(parentBtn)
	local badge = Instance.new("Frame")
	badge.Name = "NewBadge"
	badge.Size = UDim2.new(0, 30, 0, 14)
	badge.Position = UDim2.new(1, -32, 1, -18)
	badge.BackgroundColor3 = Color3.fromRGB(255, 85, 0) -- Orange-red
	badge.BorderSizePixel = 0
	badge.ZIndex = 10
	badge.Parent = parentBtn
	
	addBevel(badge, Color3.fromRGB(255, 160, 80), Color3.fromRGB(160, 40, 0))
	
	local label = Instance.new("TextLabel")
	label.Name = "NewText"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "NEW"
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextSize = 9
	label.Font = Enum.Font.Arcade
	label.ZIndex = 11
	label.Parent = badge
	
	return badge
end

-- Helper: add "!" notification dot to a tab button (MC-style square with bevel)
-- side: "left" = badge on top-left (for left category tabs), "right" = badge on top-right (for right tabs)
local function addTabNotificationBadge(tabBtn, side)
	local xPos
	if side == "right" then
		xPos = UDim2.new(1, -6, 0, -6) -- Top-right (outer edge of right tabs)
	else
		xPos = UDim2.new(0, -4, 0, -6) -- Top-left (outer edge of left tabs)
	end
	
	local dot = Instance.new("Frame")
	dot.Name = "NewNotification"
	dot.Size = UDim2.new(0, 20, 0, 20)
	dot.Position = xPos
	dot.BackgroundColor3 = Color3.fromRGB(255, 85, 0) -- Orange-red
	dot.BorderSizePixel = 0
	dot.ZIndex = 10
	dot.Parent = tabBtn
	
	addBevel(dot, Color3.fromRGB(255, 160, 80), Color3.fromRGB(160, 40, 0))
	
	local label = Instance.new("TextLabel")
	label.Name = "NotifText"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "!"
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextSize = 14
	label.Font = Enum.Font.Arcade
	label.ZIndex = 11
	label.Parent = dot
	
	return dot
end

-- Fire "mark as seen" to server for all blocks in a given category/tab
local function markTabBlocksSeen(categoryOrTabName)
	if not MarkTabSeenRemote then return end
	
	local presets = BlockPresets.GetPresetsByCategory(categoryOrTabName)
	if not presets or #presets == 0 then return end
	
	-- Only send IDs that are actually new AND visible to this player.
	-- Locked reward/rainbow blocks stay "new" until they actually appear in
	-- the grid for the first time, so the NEW badge fires when it should.
	local idsToMark = {}
	for _, preset in ipairs(presets) do
		if NewBlockIds[preset.Id] and isPresetVisible(preset) then
			table.insert(idsToMark, preset.Id)
		end
	end
	
	if #idsToMark > 0 then
		MarkTabSeenRemote:FireServer(idsToMark)
		print("[BB-NEW] Marked", #idsToMark, "blocks as seen in", categoryOrTabName)
	end
end

-- Drag-and-drop state (Minecraft-style pick up / place)
local HeldItem = nil -- { PresetId, Color, SourceSlot (nil if from creative), Count }
local HeldItemFrame = nil -- Floating UI frame that follows cursor

--====================--
--  VIEWPORT HELPERS  --
--====================--

local function createViewportPreview(parent, size)
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Viewport"
	viewport.Size = size or UDim2.new(1, 0, 1, 0)
	viewport.Position = UDim2.new(0, 0, 0, 0)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(140, 140, 140)      -- Brighter ambient for clearer small previews
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-1, -1.5, -0.5).Unit -- Top-left lighting for 3D depth
	viewport.Parent = parent
	
	local worldModel = Instance.new("WorldModel")
	worldModel.Name = "World"
	worldModel.Parent = viewport
	
	local camera = Instance.new("Camera")
	camera.FieldOfView = 39 -- Slightly narrower FOV for sharper previews
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	
	return viewport, camera, worldModel
end

-- Find a template by name in BlockTemplates
local function findTemplate(templateName)
	return BlockTemplates:FindFirstChild(templateName)
end

local function setupViewportModel(viewport, templateName, color, material, materialVariant, useBlockModel, blockModelName, isDecoration, decorationName, blockModelFolder, applyColor, leatherTint, isRainbow, stripeColorMode, isEmptyCan, brushLoadedColor, swatchLoadedColor)
	local worldModel = viewport:FindFirstChild("World")
	if not worldModel then return nil end

	-- Paint Mod: the inventory/hotbar icon uses the held models -- PaintCan (filled, colored)
	-- and PaintBrush (empty by default) -- not the ground PaintCanModel. Capture intent, then
	-- swap the can to its held model for rendering only (placement still uses PaintCanModel).
	local isPaintCanItem = (blockModelName == "PaintCanModel" or blockModelName == "PaintCan"
		or blockModelName == "PrimerPaintCanModel" or blockModelName == "PrimerPaintCan")
	local isPaintBrushItem = (blockModelName == "PaintBrush")
	local isPaintSwatchItem = (blockModelName == "PaintSwatch")
	local isPaintSpongeItem = (blockModelName == "Sponge")
	if blockModelName == "PaintCanModel" then
		blockModelName = "PaintCan"
	elseif blockModelName == "PrimerPaintCanModel" then
		blockModelName = "PrimerPaintCan"
	end
	
	for _, child in ipairs(worldModel:GetChildren()) do
		child:Destroy()
	end
	
	local model
	local isBlockModel = false
	local shouldApplyColor = applyColor -- Whether to apply the preset color
	-- Texture mode: skip Part/Model coloring; we'll tint Texture descendants below
	-- instead, so the underlying Part stays its template color and the grayscale
	-- texture pattern takes the variant color via Texture.Color3.
	local isTextureMode = stripeColorMode == "Texture"
	if isTextureMode then
		shouldApplyColor = false  -- prevent the Part-tinting branches from running
	end
	
	-- Use decoration from Decorations folder if specified
	if isDecoration and decorationName and DecorationsFolder then
		local decoTemplate = DecorationsFolder:FindFirstChild(decorationName)
		if decoTemplate then
			model = decoTemplate:Clone()
			isBlockModel = true -- Don't change colors
			
			-- Check for special positioning needs
			local isSapling = string.find(decorationName, "Sapling") ~= nil
			local isLantern = string.find(decorationName, "Lantern") ~= nil
			
			if model:IsA("BasePart") then
				model.Anchored = true
				if isLantern then
					model.Position = Vector3.new(0, -0.5, 0) -- Center lantern better
				else
					model.Position = Vector3.new(0, -1, 0) -- Lower in viewport
				end
			elseif model:IsA("Model") then
				for _, part in ipairs(model:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Anchored = true
					end
				end
				
				-- Calculate model bounds for better centering
				local cf, size = model:GetBoundingBox()
				local yOffset
				if isLantern then
					yOffset = -size.Y / 2 -- Center lantern vertically
				else
					yOffset = -size.Y / 2 - 0.5 -- Center vertically with slight offset down
				end
				model:PivotTo(CFrame.new(0, yOffset, 0))
			end
		end
	end
	
	-- Use model from specific folder if BlockModelFolder is specified
	if not model and blockModelFolder and blockModelName then
		local folder
		-- Handle nested paths like "Decorations/Glass"
		if string.find(blockModelFolder, "/") then
			local parts = string.split(blockModelFolder, "/")
			folder = ReplicatedStorage:FindFirstChild(parts[1])
			for i = 2, #parts do
				if folder then
					folder = folder:FindFirstChild(parts[i])
				end
			end
		else
			folder = ReplicatedStorage:FindFirstChild(blockModelFolder)
		end
		if folder then
			local template = folder:FindFirstChild(blockModelName)
			if template then
				model = template:Clone()
				isBlockModel = not shouldApplyColor -- Keep original colors unless ApplyColor is set
				if model:IsA("BasePart") then
					model.Anchored = true
					-- CFrame clears both position and baked-in rotation (e.g. FrameBlock has 180° Y).
					-- Tool rotation happens AFTER parenting (see below) so UnionOperations refresh.
					model.CFrame = CFrame.new(0, 0, 0)
					if shouldApplyColor then
						if color then model.Color = color end
						if material then model.Material = material end
						if type(materialVariant) == "string" and materialVariant ~= "" then
						 model.MaterialVariant = materialVariant
						end
					end
				elseif model:IsA("Model") then
					local isChestPreview = blockModelName == "SingleChest"
					local isCraftingTablePreview = blockModelName == "CraftingTable"
					local isBedPreview = blockModelName == "Bed"
					local chestTrimColor = nil
					if isChestPreview and color then
						local h, s, v = Color3.toHSV(color)
						chestTrimColor = Color3.fromHSV(h, s * 0.75, v * 0.38)
					end
					-- Crafting table: compute edge trim + tint leather Texture/Decal on Side/Top
					local ctEdgeTrimColor = nil
					if isCraftingTablePreview and color then
						local h, s, v = Color3.toHSV(color)
						ctEdgeTrimColor = Color3.fromHSV(h, s * 0.75, v * 0.38)
					end
					if isCraftingTablePreview and leatherTint then
						for _, desc in ipairs(model:GetDescendants()) do
							if (desc:IsA("Texture") or desc:IsA("Decal")) then
								local parentName = desc.Parent and desc.Parent.Name or ""
								if parentName == "Side" or parentName == "Top" then
									desc.Color3 = leatherTint
								end
							end
						end
					end
					for _, part in ipairs(model:GetDescendants()) do
						if part:IsA("BasePart") then
							part.Anchored = true
							if shouldApplyColor then
								-- Crafting table: Block=wood, Edge=darkened, Side/Top keep template
								if isCraftingTablePreview then
									if part.Name == "Block" then
										if color then part.Color = color end
										if material then part.Material = material end
										if type(materialVariant) == "string" and materialVariant ~= "" then
											part.MaterialVariant = materialVariant
										end
									elseif part.Name == "Edge" then
										if ctEdgeTrimColor then part.Color = ctEdgeTrimColor end
									end
									-- Side/Top keep template appearance
								-- Chest models: skip Darkness/Latch, darken Edge (color only)
								elseif isChestPreview then
									local group = nil
									local ancestor = part.Parent
									while ancestor and ancestor ~= model do
										local n = ancestor.Name
										if n == "Edge" or n == "Latch" or n == "Darkness" then
											group = n; break
										end
										ancestor = ancestor.Parent
									end
									if not group then
										local n = part.Name
										if n == "Edge" or n == "Latch" or n == "Darkness" then group = n end
									end
									if group == "Latch" or group == "Darkness" then continue end
									if group == "Edge" then
									 if chestTrimColor then part.Color = chestTrimColor end
									else
									 if color then part.Color = color end
									 if material then part.Material = material end
									 if type(materialVariant) == "string" and materialVariant ~= "" then
									  part.MaterialVariant = materialVariant
									 end
											end
								else
									if color then part.Color = color end
									if material then part.Material = material end
									if type(materialVariant) == "string" and materialVariant ~= "" then
										part.MaterialVariant = materialVariant
									end
								end
							end
						end
					end
					-- Bed: tint the Sheets SurfaceAppearance (BaseParts stay untouched)
					if isBedPreview and color then
						local sheets = model:FindFirstChild("Sheets")
						if sheets then
							local sa = sheets:FindFirstChildWhichIsA("SurfaceAppearance")
							if sa then
								sa.Color = color
							end
						end
					end
					-- Special positioning for different block types
					local isGlass = blockModelFolder and string.find(blockModelFolder, "Glass")
					local isTool = blockModelFolder == "Tools"
					local isLadder = blockModelName and blockModelName == "Ladder"
					local isLantern = blockModelName and blockModelName == "Lantern"
					local isFrameDoor = blockModelName and blockModelName == "FrameDoor"
					local isSignStandingFrame = blockModelName and blockModelName == "SignStandingFrame"
					local isColumn = blockModelName and blockModelName == "ColumnSingle"
					-- Paint Mod: cans/brush render straight-on like tools (not angled like blocks)
					local isPaintFlatItem = isPaintCanItem or isPaintBrushItem or isPaintSwatchItem or isPaintSpongeItem
					if isTool or isPaintFlatItem then
					-- Tools: keep authored orientation (just face camera). Tools should be
					-- authored at the angle they should display (head upper-left, etc.).
					-- Adding tilt here would over-rotate already-diagonal tool models.
						model:PivotTo(CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(180), 0))
						elseif isFrameDoor then
						-- Frame door: compensate for 90° baked-in Y rotation in Union part
						model:PivotTo(CFrame.new(0, -4.5, 0) * CFrame.Angles(0, math.rad(25 - 90), 0))
					elseif isSignStandingFrame then
					-- Standing sign frame is tall, raise slightly vs doors
					model:PivotTo(CFrame.new(0, -3.0, 0) * CFrame.Angles(0, math.rad(25), 0))
					elseif isGlass then
					model:PivotTo(CFrame.new(0, -0.5, 0))
					elseif isLadder then
					-- Rotate ladder to face camera at an angle and center it
					 model:PivotTo(CFrame.new(0, -1.5, 0) * CFrame.Angles(0, math.rad(45), 0))
					elseif isLantern then
					-- Center lantern in viewport
					 model:PivotTo(CFrame.new(0, 0.4, 0))
					elseif isColumn then
					-- Column: shift up so base/pedestal is visible
					 model:PivotTo(CFrame.new(0, -0.5, 0))
					elseif isChestPreview then
					-- Chest: flip 180° so latch/front faces camera
					 model:PivotTo(CFrame.new(0, -0.3, 0) * CFrame.Angles(0, math.rad(180), 0))
					elseif isCraftingTablePreview then
					-- Crafting table: match regular block angle
					 model:PivotTo(CFrame.new(0, -0.3, 0))
					elseif isBedPreview then
					-- Bed: center the long model and angle for best view
					 model:PivotTo(CFrame.new(1.5, -0.5, 0) * CFrame.Angles(0, math.rad(200), 0))
					-- Pull camera back further to fit the full bed
					local cam = viewport.CurrentCamera
					if cam then
						cam.CFrame = CFrame.new(Vector3.new(10, 7, 10), Vector3.new(0, 0, 0))
					end
					else
					-- Auto-detect pivot type: bottom-center vs center, and center the model accordingly
					local ok, bbCFrame = pcall(function() return model:GetBoundingBox() end)
					if ok then
						local pivotOffsetY = model.WorldPivot.Position.Y - bbCFrame.Position.Y
						if math.abs(pivotOffsetY) < 0.1 then
							-- Center pivot - already centered, no Y offset needed
							model:PivotTo(CFrame.new(0, 0, 0))
						else
							-- Bottom-center pivot - shift down so bottom sits below origin
							model:PivotTo(CFrame.new(0, -1.5, 0))
						end
					else
						-- GetBoundingBox failed (unusual model shape); fall back to old default
						model:PivotTo(CFrame.new(0, -1.5, 0))
					end
					end
				end
			end
		end
	end
	
	-- Use actual block model from Blocks folder if specified
	if not model and useBlockModel and blockModelName and BlocksFolder then
		local blockTemplate = BlocksFolder:FindFirstChild(blockModelName)
		if blockTemplate then
			model = blockTemplate:Clone()
			isBlockModel = not shouldApplyColor -- Keep original colors unless ApplyColor is set
			if model:IsA("BasePart") then
				model.Anchored = true
				model.Position = Vector3.new(0, 0, 0)
				if shouldApplyColor then
					if color then model.Color = color end
					if material then model.Material = material end
				end
			elseif model:IsA("Model") then
				for _, part in ipairs(model:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Anchored = true
						if shouldApplyColor then
							if color then part.Color = color end
							if material then part.Material = material end
						end
					end
				end
					-- Special positioning for doors (they're tall)
					local isDoor = blockModelName and (string.find(blockModelName, "Door") ~= nil)
					local isFurnace = blockModelName and blockModelName == "Furnace"
					if isDoor then
						model:PivotTo(CFrame.new(0, -4.5, 0) * CFrame.Angles(0, math.rad(25), 0))
					elseif isFurnace then
						-- Furnace: center pivot like crafting table/chest. -1.5 was the
						-- old bottom-pivot offset and pushed the model too low in the slot.
						-- Use -0.3 to match crafting table, plus 180° to face camera.
						model:PivotTo(CFrame.new(0, -0.3, 0) * CFrame.Angles(0, math.rad(180), 0))
					else
						-- Check if pivot is at center or bottom
						local bbCFrame = model:GetBoundingBox()
						local pivotOffsetY = model.WorldPivot.Position.Y - bbCFrame.Position.Y
						if math.abs(pivotOffsetY) < 0.1 then
							-- Center pivot (like GlassBlock) - just center it
							model:PivotTo(CFrame.new(0, 0, 0))
						else
							-- Bottom pivot - offset down by half block size
							model:PivotTo(CFrame.new(0, -1.5, 0))
						end
					end
			end
		end
	end
	
	if not model then
		-- Use template from BlockTemplates or Workspace and apply color/material
		local template = findTemplate(templateName)
		if not template then return nil end
		
		model = template:Clone()
		
		local function applyToPart(part)
			if part:IsA("BasePart") then
				part.Color = color or Color3.fromRGB(163, 162, 165)
				part.Material = material or Enum.Material.Plastic
				if type(materialVariant) == "string" and materialVariant ~= "" then
				part.MaterialVariant = materialVariant
				end
				part.Anchored = true
			end
		end
		
		if model:IsA("BasePart") then
			applyToPart(model)
			model.Position = Vector3.new(0, 0, 0)
		elseif model:IsA("Model") then
			for _, desc in ipairs(model:GetDescendants()) do
				applyToPart(desc)
			end
			model:PivotTo(CFrame.new(0, 0, 0))
		end
	end
	
	if not model then return nil end
	
	-- Glass material looks weird in viewports - swap to SmoothPlastic for preview only
	-- Also make frame/edge parts more transparent so they don't overpower the icon
	if model:IsA("BasePart") and model.Material == Enum.Material.Glass then
		model.Material = Enum.Material.SmoothPlastic
	elseif model:IsA("Model") then
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				if part.Material == Enum.Material.Glass then
					part.Material = Enum.Material.SmoothPlastic
				end
				-- Double the transparency on frame/edge parts for cleaner icons
				if part.Name == "Frame" then
					part.Transparency = math.min(part.Transparency * 2, 0.9)
				end
			end
		end
	end
	
	-- Colored glass icons: the pane is an invisible Part showing tinted face textures,
	-- so the generic Part-coloring above leaves the swatch grey. Apply the same
	-- colored-glass styling used in-world (tinted textures + 70% transparency +
	-- SmoothPlastic) so the icon actually shows the glass color.
	if color and applyColor and (blockModelName == "GlassPane" or blockModelName == "GlassBlock") then
		GlassPlacement.StyleColoredGlass(model, color)
	end

	model.Parent = worldModel

	-- Paint Mod: tint the can icon to its color; render the brush empty (or its loaded color)
	if isPaintCanItem then
		PaintCanVisual.ApplyCan(model, color, isEmptyCan == true)
	elseif isPaintBrushItem then
		-- Paint is per-brush: render from the slot's own loaded color (passed in), NOT the
		-- global player attribute -- so a fresh/empty brush shows blank even if another brush
		-- was loaded. nil = empty brush.
		PaintCanVisual.ApplyBrush(model, brushLoadedColor, brushLoadedColor ~= nil)
	elseif isPaintSwatchItem then
		-- Per-swatch: render from the slot's own captured color (passed in), NOT the global
		-- attribute -- so an empty swatch shows blank even if another swatch is colored.
		-- nil = empty (neutral grey, handled inside ApplySwatch).
		PaintCanVisual.ApplySwatch(model, swatchLoadedColor)
	end

	-- Apply tool rotation AFTER parenting — UnionOperations in ViewportFrames don't refresh
	-- their rendered orientation if rotated before being parented to the WorldModel.
	if blockModelFolder == "Tools" and model:IsA("BasePart") then
		model.CFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(180), 0)
	end

	local camera = viewport.CurrentCamera
	local isCandySapling = blockModelName == "CandyCaneSapling"
	if camera then
		-- Check if this is a door (needs camera further back)
		local isDoorModel = blockModelName and (string.find(blockModelName, "Door") ~= nil)
		local isLadderModel = blockModelName and blockModelName == "Ladder"
		local isToolModel = blockModelFolder == "Tools"
		local isPaintFlatItem = isPaintCanItem or isPaintBrushItem or isPaintSwatchItem or isPaintSpongeItem
		if isToolModel or isPaintFlatItem then
			-- Tools: look straight at the flat face (matches hotbar tool rendering)
			camera.CFrame = CFrame.new(Vector3.new(0, 0, 5), Vector3.new(0, 0, 0))
		elseif isCandySapling then
			-- Candy sapling: straight-on (no 45 degrees) so the stripes read cleanly in the slot
			camera.CFrame = CFrame.new(Vector3.new(0, 0, 6), Vector3.new(0, 0, 0))
		elseif isDoorModel then
			camera.CFrame = CFrame.new(Vector3.new(5.5, 5.5, 5.5), Vector3.new(0, 0, 0))
		elseif isLadderModel then
			-- Camera for ladder - standard angle works with the 45-degree rotation
			camera.CFrame = CFrame.new(Vector3.new(4, 3, 4), Vector3.new(0, 0, 0))
		else
			-- Standard camera for blocks
			camera.CFrame = CFrame.new(Vector3.new(4.5, 3.6, 4.5), Vector3.new(0, 0, 0))
		end
	end
	
	-- Candy sapling inventory icon: tint Background parts red so it reads as a
	-- classic red+white candy cane (the live placed sapling tints to its random
	-- grow-color instead; this is just the inventory/hotbar default appearance).
	if isCandySapling and model then
		local red = Color3.fromRGB(240, 30, 50)
		local function tintBg(inst)
			if inst:IsA("BasePart") and inst.Name == "Background" then
				inst.Color = red
			elseif (inst:IsA("Texture") or inst:IsA("Decal")) and inst.Parent and inst.Parent.Name == "Background" then
				inst.Color3 = red
			elseif inst:IsA("SurfaceAppearance") and inst.Parent and inst.Parent.Name == "Background" then
				inst.Color = red
			end
		end
		if model:IsA("BasePart") then tintBg(model) end
		for _, desc in ipairs(model:GetDescendants()) do tintBg(desc) end
	end
	
	-- Texture-mode tinting: walk descendants for Textures/Decals (the stripes)
	-- AND any Part named "Core" (the swirl on a candy-cane log's end caps).
	-- Other Parts (e.g. "Bark") keep their template color so the background
	-- between stripes stays white. Done after model creation so children are
	-- visible to GetDescendants().
	if isTextureMode and model and applyColor and color then
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA("Texture") or desc:IsA("Decal") then
				desc.Color3 = color
			elseif desc:IsA("BasePart") and desc.Name == "Core" then
				desc.Color = color
			end
		end
		if model:IsA("BasePart") then
			for _, child in ipairs(model:GetChildren()) do
				if child:IsA("Texture") or child:IsA("Decal") then
					child.Color3 = color
				end
			end
		end
	end
	
	-- Tag rainbow viewports so ColorCycleController can animate them
	-- Also immediately apply the current cycle color so there's no white flash
	if isRainbow then
		viewport:SetAttribute("IsRainbow", true)
		local cycleTime = os.clock()
		local hue = (cycleTime / 6.0) % 1.0
		local rainbowColor = Color3.fromHSV(hue, 0.85, 1.0)
		if model then
			if model:IsA("BasePart") then
				model.Color = rainbowColor
			elseif model:IsA("Model") then
				for _, part in ipairs(model:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Color = rainbowColor
					end
				end
			end
		end
	end
	
	return model
end

-- Setup viewport for category icon (from folder directly)
local function setupCategoryIconViewport(viewport, iconBlock, iconFolder)
	local worldModel = viewport:FindFirstChild("World")
	if not worldModel then return nil end
	
	for _, child in ipairs(worldModel:GetChildren()) do
		child:Destroy()
	end
	
	-- iconFolder may be a nested path like "Mods/PaintMod"; walk each segment from ReplicatedStorage.
	local folder = ReplicatedStorage
	for _, seg in ipairs(string.split(iconFolder, "/")) do
		folder = folder and folder:FindFirstChild(seg)
	end
	if not folder then return nil end
	
	local template = folder:FindFirstChild(iconBlock)
	if not template then return nil end
	
	local model = template:Clone()
	
	if model:IsA("BasePart") then
		model.Anchored = true
		-- CFrame clears baked-in rotation; BasePart center = origin to match where
		-- Model icons end up visually (Models use bottom pivot at -1.5, center at 0)
		model.CFrame = CFrame.new(0, 0, 0)
	elseif model:IsA("Model") then
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
		-- Offset based on model type
		local isLog = iconBlock and string.find(iconBlock, "Log")
		if not isLog then
			model:PivotTo(CFrame.new(0, -1.5, 0))
		else
			model:PivotTo(CFrame.new(0, 0, 0))
		end
	end
	
	model.Parent = worldModel
	
	local camera = viewport.CurrentCamera
	if camera then
		-- Standard camera for category icons
		camera.CFrame = CFrame.new(Vector3.new(4.5, 3.6, 4.5), Vector3.new(0, 0, 0))
	end
	
	return model
end

--====================--
--  HELPER FUNCTIONS  --
--====================--

local function updateSelection()
	-- Hide selection frames (no longer using stroke-based selection)
	if SelectionFrame then
		SelectionFrame.Visible = false
	end
	if ToolSelectionFrame then
		ToolSelectionFrame.Visible = false
	end
	
	-- Reset all hotbar slot backgrounds to normal
	if SlotFrames then
		for i = 1, HOTBAR_SLOTS do
			if SlotFrames[i] then
				SlotFrames[i].BackgroundColor3 = Colors.SlotBg
			end
		end
	end
	
	-- Reset all tool slot backgrounds to normal
	if ToolSlotFrames then
		for i = 1, 3 do
			if ToolSlotFrames[i] then
				ToolSlotFrames[i].BackgroundColor3 = Colors.SlotBg
			end
		end
	end
	
	if IsToolSlotSelected then
		-- Highlight selected tool slot with darker background
		if ToolSlotFrames and ToolSlotFrames[CurrentToolSlot] then
			ToolSlotFrames[CurrentToolSlot].BackgroundColor3 = Colors.SlotBgSelected
		end
		
		local data = ToolBelt[CurrentToolSlot]
		if BlockNameLabel then
			if data then
				local preset = BlockPresets.GetPreset(data.PresetId)
				BlockNameLabel.Text = preset and preset.Name or ""
			else
				BlockNameLabel.Text = ""
			end
		end
	else
		-- Highlight selected hotbar slot with darker background
		if SlotFrames and SlotFrames[CurrentSlot] then
			SlotFrames[CurrentSlot].BackgroundColor3 = Colors.SlotBgSelected
		end
		
		local data = Hotbar[CurrentSlot]
		if BlockNameLabel then
			if data then
				if data.IsTool then
					BlockNameLabel.Text = data.ToolName or ""
				else
					local preset = BlockPresets.GetPreset(data.PresetId)
					BlockNameLabel.Text = preset and preset.Name or ""
				end
			else
				BlockNameLabel.Text = ""
			end
		end
	end
end

-- Paint Mod: per-brush paint sync -------------------------------------------
-- Paint is per-brush: each brush slot stores its own loaded color (data.BrushLoaded +
-- data.Color/BrushIsPrimer/BrushMode). Selecting a brush tells the server to make THAT brush's
-- paint active; selecting an empty brush clears it. This is what stops a fresh brush from
-- inheriting the last color, and lets empty brushes stack while loaded ones stay separate.
local _setBrushRemote = nil
local function getSetBrushRemote()
	if _setBrushRemote then return _setBrushRemote end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	_setBrushRemote = remotes and remotes:FindFirstChild("SetBrushState")
	return _setBrushRemote
end

local function syncSelectedBrushToServer()
	if IsToolSlotSelected then return end
	local data = Hotbar[CurrentSlot]
	if not (data and data.PresetId == "PaintBrush") then return end
	local remote = getSetBrushRemote()
	if not remote then return end
	if data.BrushLoaded and data.Color then
		remote:FireServer({
			r = math.round(data.Color.R * 255),
			g = math.round(data.Color.G * 255),
			b = math.round(data.Color.B * 255),
			isPrimer = data.BrushIsPrimer and true or false,
			mode = data.BrushMode or "blend",
		})
	else
		remote:FireServer(nil) -- empty brush -> server clears active paint
	end
end

local function selectSlot(slotNumber)
	IsToolSlotSelected = false
	CurrentSlot = slotNumber
	CurrentRotation = 0
	updateSelection()
	syncSelectedBrushToServer()
end

local function selectToolSlot(slotNumber)
	IsToolSlotSelected = true
	CurrentToolSlot = slotNumber
	CurrentRotation = 0
	updateSelection()
end

local function updateHotbarSlotViewport(slotNumber)
	local slot = SlotFrames[slotNumber]
	if not slot then return end
	
	local viewport = slot:FindFirstChild("Viewport")
	if not viewport then return end
	
	local data = Hotbar[slotNumber]
	
	-- Handle tool items
	if data and data.IsTool then
		local worldModel = viewport:FindFirstChild("World")
		if not worldModel then return end
		
		-- Clear existing
		for _, child in ipairs(worldModel:GetChildren()) do
			child:Destroy()
		end
		
		-- Get tool from Tools folder
		if not ToolsFolder then return end
		local toolTemplate = ToolsFolder:FindFirstChild(data.ToolName)
		if not toolTemplate then return end
		
		local model = toolTemplate:Clone()
		
		-- Tools render with the orientation they were authored in Studio (just
		-- face the camera). If you want a diagonal Minecraft look, author the tool
		-- model diagonally — don't add tilt here, that would over-rotate it.
		local toolRotation = CFrame.Angles(0, math.rad(180), 0)
		if model:IsA("BasePart") then
			model.Anchored = true
			model.CFrame = CFrame.new(0, 0, 0) * toolRotation
		elseif model:IsA("Model") then
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
				end
			end
			model:PivotTo(CFrame.new(0, 0, 0) * toolRotation)
		end
		model.Parent = worldModel
		
		-- Camera looks straight at the flat face, close enough to fill the slot
		local camera = viewport.CurrentCamera
		if camera then
			camera.CFrame = CFrame.new(Vector3.new(0, 0, 5), Vector3.new(0, 0, 0))
		end
		return
	end
	
	-- Handle block items
	if data then
		local preset = BlockPresets.GetPreset(data.PresetId)
		if preset then
			local shape = BlockPresets.GetShape(preset.Shape)
			if shape then
				setupViewportModel(
				viewport, 
				shape.TemplateName, 
				data.Color, 
				preset.Material,
				preset.MaterialVariant,
				preset.UseBlockModel,
				preset.BlockModelName,
				preset.IsDecoration,
				preset.DecorationName,
				preset.BlockModelFolder,
				preset.ApplyColor,
				preset.LeatherTint,
				preset.IsRainbow,
				preset.StripeColorMode,
				preset.IsEmptyCan, -- isEmptyCan: empty cans render the empty model, not the painted one
				(data.BrushLoaded and data.Color or nil), -- brushLoadedColor: per-slot brush paint
				(data.SwatchLoaded and data.Color or nil) -- swatchLoadedColor: per-slot swatch color
			)
			end
		end
	else
		local worldModel = viewport:FindFirstChild("World")
		if worldModel then
			for _, child in ipairs(worldModel:GetChildren()) do
				child:Destroy()
			end
		end
	end
	
	-- Update stack count label
	local countLabel = slot:FindFirstChild("CountLabel")
	if countLabel then
		if data and data.Count and data.Count > 1 then
			countLabel.Text = tostring(data.Count)
			countLabel.Visible = true
		else
			countLabel.Text = ""
			countLabel.Visible = false
		end
	end
end

local function updateToolSlotViewport(slotNumber)
	if not ToolSlotFrames then return end
	local slot = ToolSlotFrames[slotNumber]
	if not slot then return end
	
	local viewport = slot:FindFirstChild("Viewport")
	if not viewport then return end
	
	local data = ToolBelt[slotNumber]
	
	if data then
		local preset = BlockPresets.GetPreset(data.PresetId)
		if preset then
			local shape = BlockPresets.GetShape(preset.Shape)
			if shape then
					setupViewportModel(
					viewport, 
					shape.TemplateName, 
					data.Color, 
					preset.Material,
					preset.MaterialVariant,
					preset.UseBlockModel,
					preset.BlockModelName,
					preset.IsDecoration,
					preset.DecorationName,
					preset.BlockModelFolder,
					preset.ApplyColor,
					preset.LeatherTint,
					preset.IsRainbow
				)
			end
		end
	else
		local worldModel = viewport:FindFirstChild("World")
		if worldModel then
			for _, child in ipairs(worldModel:GetChildren()) do
				child:Destroy()
			end
		end
	end
end

local function findFirstEmptySlot()
	for i = 1, HOTBAR_SLOTS do
		if not Hotbar[i] then
			return i
		end
	end
	return nil -- All full
end

local function findFirstEmptyToolSlot()
	for i = 1, 3 do
		-- Skip permanent tool slots
		if not PermanentTools[i] and not ToolBelt[i] then
			return i
		end
	end
	return nil -- All full
end

local function addPresetToHotbar(presetId)
	local preset = BlockPresets.GetPreset(presetId)
	if not preset then return end
	
	-- Skip if this is a permanent tool (already in tool belt)
	for _, permToolId in pairs(PermanentTools) do
		if permToolId == presetId then
			return -- Don't add permanent tools from inventory
		end
	end
	
	-- Route tools to tool belt (if enabled), blocks to hotbar
	if SHOW_TOOL_BELT and (preset.IsTool or preset.IsWiringTool) then
		-- Check if already in tool belt — if so, just select it
		for i = 1, TOOL_BELT_SLOTS do
			if ToolBelt[i] and ToolBelt[i].PresetId == presetId then
				selectToolSlot(i)
				return
			end
		end
		
		-- Add to tool belt
		local slot = findFirstEmptyToolSlot()
		if not slot then
			-- Tool belt full, replace current tool slot
			slot = CurrentToolSlot
		end
		
		ToolBelt[slot] = {
			PresetId = presetId,
			Color = preset.DefaultColor,
		}
		
		updateToolSlotViewport(slot)
		selectToolSlot(slot)
		
		-- Flash feedback
		if ToolSlotFrames then
			local slotFrame = ToolSlotFrames[slot]
			if slotFrame then
				local original = slotFrame.BackgroundColor3
				slotFrame.BackgroundColor3 = Colors.Success
				task.delay(0.15, function()
					TweenService:Create(slotFrame, TweenInfo.new(0.2), {BackgroundColor3 = original}):Play()
				end)
			end
		end
	else
		-- Check if already in hotbar with room to stack. A loaded brush/swatch is its own item
		-- and never receives a merge -- only EMPTY ones stack -- so skip slots already colored.
		-- (This is also why a new empty brush/swatch starts a fresh stack when you only have
		-- colored ones: every colored slot is skipped, so it lands in a new slot.)
		for i = 1, HOTBAR_SLOTS do
			if Hotbar[i] and Hotbar[i].PresetId == presetId
				and not Hotbar[i].BrushLoaded and not Hotbar[i].SwatchLoaded then
				local count = Hotbar[i].Count or 1
				if count < MAX_STACK then
					-- Increment existing stack
					Hotbar[i].Count = count + 1
					updateHotbarSlotViewport(i)
					selectSlot(i)
					
					-- Flash feedback
					local slotFrame = SlotFrames[i]
					if slotFrame then
						local original = slotFrame.BackgroundColor3
						slotFrame.BackgroundColor3 = Colors.Success
						task.delay(0.15, function()
							TweenService:Create(slotFrame, TweenInfo.new(0.2), {BackgroundColor3 = original}):Play()
						end)
					end
					return
				end
				-- This slot is full (64), keep looking for another stack or empty slot
			end
		end
		
		-- No existing stack with room — add to a new slot
		local slot = findFirstEmptySlot()
		if not slot then
			-- Hotbar full, replace current slot
			slot = CurrentSlot
		end
		
		Hotbar[slot] = {
			PresetId = presetId,
			Color = preset.DefaultColor,
			Count = 1,
		}
		
		updateHotbarSlotViewport(slot)
		selectSlot(slot)
		
		-- Flash feedback
		local slotFrame = SlotFrames[slot]
		if slotFrame then
			local original = slotFrame.BackgroundColor3
			slotFrame.BackgroundColor3 = Colors.Success
			task.delay(0.15, function()
				TweenService:Create(slotFrame, TweenInfo.new(0.2), {BackgroundColor3 = original}):Play()
			end)
		end
	end
end

-- ============================================
-- SPLIT A LOADED PAINT ITEM OFF A STACK (Minecraft-style)
-- Used when loading a brush from a can or capturing a color with a swatch while a STACK of
-- empties is selected: peel one off into a new slot and apply the loaded fields to it, leaving
-- the rest of the stack untouched. A single (Count 1) item is just loaded in place.
-- loadedFields = extra fields for the loaded item, e.g. { BrushLoaded=true, Color=c, ... }.
-- ============================================
local function splitLoadedPaintItem(loadedFields)
	if IsToolSlotSelected then return end
	local src = Hotbar[CurrentSlot]
	if not src then return end
	local count = src.Count or 1

	-- Single item: load it in place.
	if count <= 1 then
		for k, v in pairs(loadedFields) do src[k] = v end
		src.Count = 1
		updateHotbarSlotViewport(CurrentSlot)
		return CurrentSlot
	end

	-- Stack: peel one off into a new slot. If the hotbar is full, fall back to loading the
	-- whole stack in place (rare edge -- nowhere to put the split item).
	local target = findFirstEmptySlot()
	if not target then
		for k, v in pairs(loadedFields) do src[k] = v end
		updateHotbarSlotViewport(CurrentSlot)
		return CurrentSlot
	end

	src.Count = count - 1
	updateHotbarSlotViewport(CurrentSlot)

	local newItem = { PresetId = src.PresetId, Count = 1 }
	for k, v in pairs(loadedFields) do newItem[k] = v end
	Hotbar[target] = newItem
	updateHotbarSlotViewport(target)
	selectSlot(target) -- equip the freshly loaded item (also syncs brush paint to the server)
	return target
end

-- ============================================
-- GRANT ITEM (stations like the Paint Mixer hand a finished item to the player)
-- Places into the first empty hotbar slot. Returns true on success, false if the
-- hotbar is full (caller decides what to do then). Color may be a Color3 override.
-- ============================================
local function grantItem(presetId, color, count)
	local preset = BlockPresets.GetPreset(presetId)
	if not preset then return false end
	local slot = findFirstEmptySlot()
	if not slot then return false end
	Hotbar[slot] = {
		PresetId = presetId,
		Color = color or preset.DefaultColor,
		Count = count or 1,
	}
	updateHotbarSlotViewport(slot)
	if slot == CurrentSlot and not IsToolSlotSelected then updateSelection() end
	return true
end

-- ============================================
-- DRAG-AND-DROP (Minecraft-style pick up / place)
-- ============================================

local function createHeldItemUI(presetId, count)
	local preset = BlockPresets.GetPreset(presetId)
	if not preset then return end

	-- Destroy old frame if exists
	if HeldItemFrame then
		HeldItemFrame:Destroy()
		HeldItemFrame = nil
	end

	local size = 52
	local frame = Instance.new("Frame")
	frame.Name = "HeldItem"
	frame.Size = UDim2.new(0, size, 0, size)
	frame.BackgroundTransparency = 1
	frame.ZIndex = 200
	frame.Parent = ScreenGui

	local viewport = createViewportPreview(frame, UDim2.new(1, -6, 1, -6))
	viewport.Position = UDim2.new(0, 3, 0, 3)
	viewport.ZIndex = 201
	viewport.BackgroundTransparency = 1

	local shape = BlockPresets.GetShape(preset.Shape)
	if shape then
		setupViewportModel(
			viewport,
			shape.TemplateName,
			preset.DefaultColor,
			preset.Material,
			preset.MaterialVariant,
			preset.UseBlockModel,
			preset.BlockModelName,
			preset.IsDecoration,
			preset.DecorationName,
			preset.BlockModelFolder,
			preset.ApplyColor,
			preset.LeatherTint,
			preset.IsRainbow,
			preset.StripeColorMode,
			preset.IsEmptyCan
		)
	end
	
	-- Stack count label (bottom-right, Minecraft style)
	if count and count > 1 then
		local countLabel = Instance.new("TextLabel")
		countLabel.Name = "CountLabel"
		countLabel.Size = UDim2.new(0, 24, 0, 16)
		countLabel.Position = UDim2.new(1, -26, 1, -18)
		countLabel.BackgroundTransparency = 1
		countLabel.Text = tostring(count)
		countLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		countLabel.TextSize = 14
		countLabel.Font = Enum.Font.GothamBold
		countLabel.TextXAlignment = Enum.TextXAlignment.Right
		countLabel.ZIndex = 202
		countLabel.Parent = frame
		
		local countStroke = Instance.new("UIStroke")
		countStroke.Color = Color3.fromRGB(30, 30, 30)
		countStroke.Thickness = 1.5
		countStroke.Parent = countLabel
	end

	HeldItemFrame = frame
end

local function pickUpItem(presetId, color, sourceSlot, count)
	local itemCount = count or (sourceSlot and Hotbar[sourceSlot] and Hotbar[sourceSlot].Count) or 1
	
	HeldItem = {
		PresetId = presetId,
		Color = color,
		SourceSlot = sourceSlot, -- nil if from creative grid
		Count = itemCount,
	}

	-- Clear the source hotbar slot if picking up from hotbar
	if sourceSlot then
		Hotbar[sourceSlot] = nil
		updateHotbarSlotViewport(sourceSlot)
		if sourceSlot == CurrentSlot then
			updateSelection()
		end
	end

	createHeldItemUI(presetId, itemCount)
end

local function dropItemOnSlot(slotNumber)
	if not HeldItem then return end

	-- If the target slot already has a block, swap: pick up the old one
	local existingData = Hotbar[slotNumber]

	-- Place held item into the slot
	Hotbar[slotNumber] = {
		PresetId = HeldItem.PresetId,
		Color = HeldItem.Color,
		Count = HeldItem.Count or 1,
	}
	updateHotbarSlotViewport(slotNumber)
	selectSlot(slotNumber)

	-- Flash feedback
	local slotFrame = SlotFrames[slotNumber]
	if slotFrame then
		local original = slotFrame.BackgroundColor3
		slotFrame.BackgroundColor3 = Colors.Success
		task.delay(0.15, function()
			TweenService:Create(slotFrame, TweenInfo.new(0.2), {BackgroundColor3 = original}):Play()
		end)
	end

	if existingData and existingData.PresetId then
		-- Swap: pick up the old item
		HeldItem = nil
		if HeldItemFrame then
			HeldItemFrame:Destroy()
			HeldItemFrame = nil
		end
		pickUpItem(existingData.PresetId, existingData.Color, nil, existingData.Count)
	else
		-- No swap, just clear held item
		HeldItem = nil
		if HeldItemFrame then
			HeldItemFrame:Destroy()
			HeldItemFrame = nil
		end
	end
end

local function cancelHeldItem()
	-- If picked up from a hotbar slot, put it back
	if HeldItem and HeldItem.SourceSlot then
		local slot = HeldItem.SourceSlot
		Hotbar[slot] = {
			PresetId = HeldItem.PresetId,
			Color = HeldItem.Color,
			Count = HeldItem.Count or 1,
		}
		updateHotbarSlotViewport(slot)
		updateSelection()
	end

	HeldItem = nil
	if HeldItemFrame then
		HeldItemFrame:Destroy()
		HeldItemFrame = nil
	end
end

-- Check if shift is held (desktop only) - declared early for use in slot click handlers
local function isShiftHeld()
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

-- Forward declarations for functions used in slot click handlers before definition
local quickTransferToHotbar
local quickTransferToSurvival

local function updateMobileButtonsVisibility()
	if MobileButtonsFrame then
		MobileButtonsFrame.Visible = not InventoryOpen
	end
end

local function isAnyOverlayOpen()
	-- Title screen or world creator/settings UI
	if _G.TitleScreen and _G.TitleScreen.IsOpen and _G.TitleScreen.IsOpen() then return true end
	if _G.PrivateServerSettingsUI and _G.PrivateServerSettingsUI.IsOpen and _G.PrivateServerSettingsUI.IsOpen() then return true end
	if _G.BiomeUI and _G.BiomeUI.IsOpen and _G.BiomeUI.IsOpen() then return true end
	if _G.PlayerInteractionUI and _G.PlayerInteractionUI.IsOpen and _G.PlayerInteractionUI.IsOpen() then return true end
	if _G.SignEditController and _G.SignEditController.IsEditing and _G.SignEditController.IsEditing() then return true end
	local saveLoadUI = PlayerGui:FindFirstChild("SaveLoadUI")
	if saveLoadUI and saveLoadUI.Enabled then return true end
	return false
end

-- Background blur for inventory
local InventoryBlur = Instance.new("BlurEffect")
InventoryBlur.Name = "InventoryBlur"
InventoryBlur.Size = 0
InventoryBlur.Enabled = true
InventoryBlur.Parent = Lighting

local function openInventory()
	if isAnyOverlayOpen() then return end
	-- Can't open inventory while laying on a bed (player would have to stand up first)
	if _G.BedController and _G.BedController.IsLayingDown() then return end
	if InventoryPanel then
		InventoryPanel.Visible = true
		InventoryOpen = true
		updateMobileButtonsVisibility()
		-- Blur background
		TweenService:Create(InventoryBlur, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = 12}):Play()
	end
end

local function closeInventory()
	if InventoryPanel then
		InventoryPanel.Visible = false
		InventoryOpen = false
		-- Cancel any held drag-and-drop item
		cancelHeldItem()
		-- Hide any lingering tooltip
		if CategoryTooltip then
			CategoryTooltip.Visible = false
		end
		-- Clear search
		if SearchBox then
			SearchBox.Text = ""
		end
		CurrentSearchQuery = ""
		updateMobileButtonsVisibility()
		-- Remove blur
		TweenService:Create(InventoryBlur, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = 0}):Play()
	end
end

local function toggleInventory()
	if InventoryOpen then
		closeInventory()
	else
		openInventory()
	end
end

local function getSelectedBlock()
	local data
	
	if IsToolSlotSelected then
		data = ToolBelt[CurrentToolSlot]
	else
		data = Hotbar[CurrentSlot]
	end
	
	if not data then return nil end
	
	-- Water bucket tools return special data for placement
	if data.IsTool then
		if data.ToolName == "WaterBucket" then
			return {
				Id = "WaterBucket",
				Name = "Water Bucket",
				IsTool = true,
				IsWaterBucket = true,
			}
		elseif data.ToolName == "EmptyBucket" then
			return {
				Id = "EmptyBucket",
				Name = "Empty Bucket",
				IsTool = true,
				IsEmptyBucket = true,
			}
		elseif data.ToolName == "PaintBrush" then
			-- Paint Mod: brush may linger as a stale tool-slot entry from when it was IsTool.
			-- Expose IsPaintbrush so the brush engine + gate treat it correctly (not a wiring tool).
			return {
				Id = "PaintBrush",
				Name = "Paint Brush",
				IsPaintbrush = true,
			}
		end
		return nil -- Regular tools don't place blocks
	end
	
	local preset = BlockPresets.GetPreset(data.PresetId)
	if not preset then return nil end
	
	local shape = BlockPresets.GetShape(preset.Shape)
	if not shape then return nil end
	
	return {
		Id = data.PresetId,
		Name = preset.Name,
		Shape = preset.Shape,
		TemplateName = shape.TemplateName,
		Offset = shape.Offset,
		CanRotate = shape.CanRotate,
		Material = preset.Material,
		MaterialVariant = preset.MaterialVariant,
		Color = data.Color,
		DefaultColor = preset.DefaultColor,
		UseBlockModel = preset.UseBlockModel,
		BlockModelName = preset.BlockModelName,
		BlockModelFolder = preset.BlockModelFolder,
		IsDecoration = preset.IsDecoration,
		DecorationName = preset.DecorationName,
		IsTool = preset.IsTool,
		IsWiringTool = preset.IsWiringTool,
		IsController = preset.IsController,
		IsControllable = preset.IsControllable,
		ApplyColor = preset.ApplyColor,
		IsFence = preset.IsFence,
		IsDoor = preset.IsDoor,
		IsFrameBlock = preset.IsFrameBlock,
		IsPaintbrush = preset.IsPaintbrush, -- Paint Mod: routes right-click to the brush engine
	}
end

local function rotateBlock()
	local data = Hotbar[CurrentSlot]
	if not data then return end
	
	local preset = BlockPresets.GetPreset(data.PresetId)
	if not preset then return end
	
	local shape = BlockPresets.GetShape(preset.Shape)
	if shape and shape.CanRotate then
		CurrentRotation = (CurrentRotation + 90) % 360
	end
end

--====================--
--    HOTBAR UI       --
--====================--

-- Create a tool belt slot (matches main hotbar styling)
local function createToolSlot(slotNumber)
	local slotSize = IsMobile and 50 or 60
	
	local slot = Instance.new("TextButton")
	slot.Name = "ToolSlot" .. slotNumber
	slot.Size = UDim2.new(0, slotSize, 0, slotSize)
	slot.BackgroundColor3 = Colors.SlotBg
	slot.BackgroundTransparency = 0.35
	slot.BorderSizePixel = 0
	slot.Text = ""
	slot.AutoButtonColor = false
	
	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.Border
	stroke.Thickness = 1
	stroke.Transparency = 0.3
	stroke.Parent = slot
	
	-- Key hint labels (Q, Z, X)
	local keyHints = {"Q", "Z", "X"}
	local numLabel = Instance.new("TextLabel")
	numLabel.Name = "KeyHint"
	numLabel.Position = UDim2.new(0, 4, 0, 2)
	numLabel.Size = UDim2.new(0, 14, 0, 14)
	numLabel.BackgroundTransparency = 1
	numLabel.Text = keyHints[slotNumber] or ""
	numLabel.TextColor3 = Color3.fromRGB(160, 160, 160) -- Light text on dark slot
	numLabel.TextSize = IsMobile and 10 or 12
	numLabel.Font = Enum.Font.Arcade
	numLabel.ZIndex = 3
	numLabel.Visible = not IsMobile
	numLabel.Parent = slot
	
	local viewport = createViewportPreview(slot, UDim2.new(1, -8, 1, -8))
	viewport.Position = UDim2.new(0, 4, 0, 4)
	viewport.ZIndex = 2
	
	addInsetBevel(slot)
	
	slot.MouseButton1Click:Connect(function()
		selectToolSlot(slotNumber)
	end)
	
	-- Right-click to clear tool slot (but not permanent tools)
	slot.MouseButton2Click:Connect(function()
		if PermanentTools[slotNumber] then
			return -- Can't remove permanent tools
		end
		ToolBelt[slotNumber] = nil
		updateToolSlotViewport(slotNumber)
		if slotNumber == CurrentToolSlot and IsToolSlotSelected then
			updateSelection()
		end
	end)
	
	return slot
end

local function createHotbarSlot(slotNumber)
	local slotSize = IsMobile and 48 or 58
	
	local slot = Instance.new("TextButton")
	slot.Name = "Slot" .. slotNumber
	slot.Size = UDim2.new(0, slotSize, 0, slotSize)
	slot.BackgroundColor3 = Colors.SlotBg
	slot.BackgroundTransparency = 0.35
	slot.BorderSizePixel = 0
	slot.Text = ""
	slot.AutoButtonColor = false
	
	local stroke = Instance.new("UIStroke")
	stroke.Color = Colors.Border
	stroke.Thickness = 1
	stroke.Transparency = 0.3
	stroke.Parent = slot
	
	-- Hide slot numbers on mobile to save space
	local numLabel = Instance.new("TextLabel")
	numLabel.Name = "Number"
	numLabel.Position = UDim2.new(0, 4, 0, 2)
	numLabel.Size = UDim2.new(0, 14, 0, 14)
	numLabel.BackgroundTransparency = 1
	numLabel.Text = tostring(slotNumber)
	numLabel.TextColor3 = Color3.fromRGB(180, 180, 180) -- Light text on dark slot
	numLabel.TextSize = IsMobile and 10 or 12
	numLabel.Font = Enum.Font.Arcade
	numLabel.ZIndex = 3
	numLabel.Visible = not IsMobile
	numLabel.Parent = slot
	
	local viewport = createViewportPreview(slot, UDim2.new(1, -8, 1, -8))
	viewport.Position = UDim2.new(0, 4, 0, 4)
	viewport.ZIndex = 2
	
	addInsetBevel(slot)
	
	-- Stack count label (bottom-right, white text with dark stroke like Minecraft)
	local countLabel = Instance.new("TextLabel")
	countLabel.Name = "CountLabel"
	countLabel.Size = UDim2.new(0, 28, 0, 16)
	countLabel.Position = UDim2.new(1, -30, 1, -18)
	countLabel.BackgroundTransparency = 1
	countLabel.Text = ""
	countLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	countLabel.TextSize = IsMobile and 12 or 14
	countLabel.Font = Enum.Font.GothamBold
	countLabel.TextXAlignment = Enum.TextXAlignment.Right
	countLabel.ZIndex = 6
	countLabel.Visible = false
	countLabel.Parent = slot
	
	local countStroke = Instance.new("UIStroke")
	countStroke.Color = Color3.fromRGB(30, 30, 30)
	countStroke.Thickness = 1.5
	countStroke.Parent = countLabel
	
	-- Long-press tracking for mobile drag-and-drop
	local slotPressStart = nil
	local slotLongPressFired = false
	local SLOT_LONG_PRESS_TIME = 0.35
	
	slot.MouseButton1Down:Connect(function()
		slotPressStart = tick()
		slotLongPressFired = false
		
		if IsMobile and not HeldItem then
			local blockUIOpen = _G.BlockInteractionController and _G.BlockInteractionController.IsAnyBlockUIOpen and _G.BlockInteractionController.IsAnyBlockUIOpen()
			if InventoryOpen or blockUIOpen then
				-- Start long-press timer for mobile pickup
				local startTime = slotPressStart
				task.delay(SLOT_LONG_PRESS_TIME, function()
					if slotPressStart == startTime and not slotLongPressFired then
						slotLongPressFired = true
						local data = Hotbar[slotNumber]
						if data and data.PresetId then
							pickUpItem(data.PresetId, data.Color, slotNumber)
						end
					end
				end)
			end
		end
	end)
	
	slot.MouseButton1Up:Connect(function()
		slotPressStart = nil
	end)
	
	slot.MouseButton1Click:Connect(function()
		if slotLongPressFired then return end -- Already handled by long-press
		
		local blockUIOpen = _G.BlockInteractionController and _G.BlockInteractionController.IsAnyBlockUIOpen and _G.BlockInteractionController.IsAnyBlockUIOpen()
		if InventoryOpen or blockUIOpen then
			-- Shift-click: quick-transfer to open chest/survival inventory
			if not IsMobile and isShiftHeld() and not HeldItem then
				local data = Hotbar[slotNumber]
				if data and data.PresetId then
					local colorArray = nil
					if data.Color then
						colorArray = {
							math.floor(data.Color.R * 255 + 0.5),
							math.floor(data.Color.G * 255 + 0.5),
							math.floor(data.Color.B * 255 + 0.5),
						}
					end
					local item = { p = data.PresetId, c = colorArray, n = data.Count or 1 }
					local transferred = false
					
					-- Try chest first, then survival
					if _G.ChestUI and _G.ChestUI.IsOpen() and _G.ChestUI.QuickTransferIn then
						transferred = _G.ChestUI.QuickTransferIn(item)
					elseif SelectedCategory == "Inventory" then
						transferred = quickTransferToSurvival(item)
					end
					
					if transferred then
						Hotbar[slotNumber] = nil
						updateHotbarSlotViewport(slotNumber)
						if slotNumber == CurrentSlot then updateSelection() end
					end
				end
				return
			end
			
			-- Drag-and-drop mode (inventory or block UI is open)
			if HeldItem then
				-- Holding something: drop it into this slot
				dropItemOnSlot(slotNumber)
			elseif not IsMobile then
				-- Desktop: click to pick up block from this slot
				local data = Hotbar[slotNumber]
				if data and data.PresetId then
					pickUpItem(data.PresetId, data.Color, slotNumber)
				end
			end
			-- Mobile tap without holding: do nothing (need long-press to pick up)
		else
			-- Normal mode: just select the slot
			selectSlot(slotNumber)
		end
	end)
	
	slot.MouseButton2Click:Connect(function()
		-- Right-click clears the slot. Works whether inventory is open or closed.
		-- Skip if currently holding a drag-and-drop item — the global handler
		-- in that case treats right-click as "cancel held item".
		if HeldItem then return end
		Hotbar[slotNumber] = nil
		updateHotbarSlotViewport(slotNumber)
		if slotNumber == CurrentSlot then
			updateSelection()
		end
	end)
	
	return slot
end

local function createHotbarUI()
	ScreenGui = Instance.new("ScreenGui")
	ScreenGui.Name = "InventoryGui"
	ScreenGui.ResetOnSpawn = false
	ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	ScreenGui.DisplayOrder = 100 -- Render on top of other UIs
	ScreenGui.Parent = PlayerGui
	
	-- Mobile-responsive hotbar sizing
	local slotSize = IsMobile and 48 or 58
	local slotPad = 4
	local hotbarWidth = slotSize * HOTBAR_SLOTS + slotPad * (HOTBAR_SLOTS - 1) + 8
	local hotbarHeight = IsMobile and 60 or 70
	local bottomOffset = IsMobile and -8 or -12
	
	-- Tool belt sizing (3 slots)
	local toolBeltWidth = IsMobile and (slotSize * 3 + 2 * 5 + 16) or 210
	local toolBeltGap = IsMobile and 8 or 12 -- Gap between tool belt and hotbar
	
	-- Calculate total width and offset for centering
	local totalWidth = toolBeltWidth + toolBeltGap + hotbarWidth
	local toolBeltOffset = -(totalWidth / 2) + (toolBeltWidth / 2)
	local hotbarOffset = (totalWidth / 2) - (hotbarWidth / 2)
	
	-- If tool belt is hidden, center the hotbar instead
	if not SHOW_TOOL_BELT then
		hotbarOffset = 0
	end
	
	--====================--
	--     TOOL BELT      --
	--====================--
	
	ToolSlotFrames = {}
	
	ToolBeltFrame = Instance.new("Frame")
	ToolBeltFrame.Name = "ToolBelt"
	ToolBeltFrame.AnchorPoint = Vector2.new(0.5, 1)
	ToolBeltFrame.Position = UDim2.new(0.5, toolBeltOffset, 1, bottomOffset)
	ToolBeltFrame.Size = UDim2.new(0, toolBeltWidth, 0, hotbarHeight)
	ToolBeltFrame.BackgroundColor3 = Colors.HotbarBg
	ToolBeltFrame.BackgroundTransparency = 0
	ToolBeltFrame.BorderSizePixel = 0
	ToolBeltFrame.Parent = ScreenGui
	
	ToolBeltFrame.BackgroundTransparency = 0.15
	
	addBevel(ToolBeltFrame)
	
	local toolSlotsContainer = Instance.new("Frame")
	toolSlotsContainer.Name = "ToolSlots"
	toolSlotsContainer.Size = UDim2.new(1, 0, 1, 0)
	toolSlotsContainer.BackgroundTransparency = 1
	toolSlotsContainer.Parent = ToolBeltFrame
	
	local toolLayout = Instance.new("UIListLayout")
	toolLayout.FillDirection = Enum.FillDirection.Horizontal
	toolLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	toolLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	toolLayout.Padding = UDim.new(0, 5)
	toolLayout.Parent = toolSlotsContainer
	
	for i = 1, 3 do
		local slot = createToolSlot(i)
		slot.Parent = toolSlotsContainer
		ToolSlotFrames[i] = slot
	end
	
	-- Tool belt selection frame
	local toolSelectionSize = IsMobile and 58 or 68
	ToolSelectionFrame = Instance.new("Frame")
	ToolSelectionFrame.Name = "ToolSelection"
	ToolSelectionFrame.Size = UDim2.new(0, toolSelectionSize, 0, toolSelectionSize)
	ToolSelectionFrame.Position = UDim2.new(0, 0, 0.5, -toolSelectionSize/2)
	ToolSelectionFrame.BackgroundTransparency = 1
	ToolSelectionFrame.BorderSizePixel = 0
	ToolSelectionFrame.ZIndex = 0
	ToolSelectionFrame.Visible = false
	ToolSelectionFrame.Parent = ToolBeltFrame
	
	local toolSelStroke = Instance.new("UIStroke")
	toolSelStroke.Color = Colors.Selected
	toolSelStroke.Thickness = 4
	toolSelStroke.Parent = ToolSelectionFrame
	
	-- Hide tool belt if feature is disabled
	ToolBeltFrame.Visible = SHOW_TOOL_BELT
	
	--====================--
	--    MAIN HOTBAR     --
	--====================--
	
	HotbarFrame = Instance.new("Frame")
	HotbarFrame.Name = "Hotbar"
	HotbarFrame.AnchorPoint = Vector2.new(0.5, 1)
	HotbarFrame.Position = UDim2.new(0.5, hotbarOffset, 1, bottomOffset)
	HotbarFrame.Size = UDim2.new(0, hotbarWidth, 0, hotbarHeight)
	HotbarFrame.BackgroundColor3 = Colors.HotbarBg
	HotbarFrame.BackgroundTransparency = 0.35
	HotbarFrame.BorderSizePixel = 0
	HotbarFrame.Parent = ScreenGui
	
	addBevel(HotbarFrame)
	
	local slotsContainer = Instance.new("Frame")
	slotsContainer.Name = "Slots"
	slotsContainer.Size = UDim2.new(1, 0, 1, 0)
	slotsContainer.BackgroundTransparency = 1
	slotsContainer.Parent = HotbarFrame
	
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, slotPad)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = slotsContainer
	
	for i = 1, HOTBAR_SLOTS do
		local slot = createHotbarSlot(i)
		slot.LayoutOrder = i
		slot.Parent = slotsContainer
		SlotFrames[i] = slot
	end
	
	-- Selection frame (rendered on top of slots)
	-- Make it 4px larger than slots so the stroke wraps around nicely
	local selectionPadding = 4
	local selectionSize = slotSize + selectionPadding
	SelectionFrame = Instance.new("Frame")
	SelectionFrame.Name = "Selection"
	SelectionFrame.Size = UDim2.new(0, selectionSize, 0, selectionSize)
	SelectionFrame.Position = UDim2.new(0, 0, 0.5, -selectionSize/2)
	SelectionFrame.BackgroundTransparency = 1
	SelectionFrame.BorderSizePixel = 0
	SelectionFrame.ZIndex = 10 -- Above slots
	SelectionFrame.Parent = HotbarFrame
	
	local selStroke = Instance.new("UIStroke")
	selStroke.Color = Colors.Selected
	selStroke.Thickness = 3
	selStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	selStroke.Parent = SelectionFrame
	
	BlockNameLabel = Instance.new("TextLabel")
	BlockNameLabel.Name = "BlockName"
	BlockNameLabel.AnchorPoint = Vector2.new(0.5, 1)
	BlockNameLabel.Position = UDim2.new(0.5, 0, 0, -8)
	BlockNameLabel.Size = UDim2.new(0, 200, 0, 20)
	BlockNameLabel.BackgroundTransparency = 1
	BlockNameLabel.TextColor3 = Color3.fromRGB(255, 255, 255) -- White over game world
	BlockNameLabel.TextSize = 15
	BlockNameLabel.Font = Enum.Font.Arcade
	BlockNameLabel.TextStrokeTransparency = 0.5
	BlockNameLabel.Text = ""
	BlockNameLabel.Parent = HotbarFrame
	
	task.delay(0.1, updateSelection)
end

--====================--
--   INVENTORY UI     --
--====================--

local function createPresetButton(preset, parent)
	-- Square cells like MC inventory slots
	local btnWidth = IsMobile and 58 or 64
	local btnHeight = IsMobile and 58 or 64
	
	local btn = Instance.new("TextButton")
	btn.Name = preset.Id
	btn.Size = UDim2.new(0, btnWidth, 0, btnHeight)
	btn.BackgroundColor3 = Colors.CellBg
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.Parent = parent
	
	addInsetBevel(btn)
	
	-- Viewport fills most of the cell (MC-style)
	local viewport = createViewportPreview(btn, UDim2.new(1, -12, 1, -12))
	viewport.Position = UDim2.new(0, 6, 0, 6)
	
	local shape = BlockPresets.GetShape(preset.Shape)
	if shape then
		setupViewportModel(
			viewport, 
			shape.TemplateName, 
			preset.DefaultColor, 
			preset.Material,
			preset.MaterialVariant,
			preset.UseBlockModel,
			preset.BlockModelName,
			preset.IsDecoration,
			preset.DecorationName,
			preset.BlockModelFolder,
			preset.ApplyColor,
			preset.LeatherTint,
			preset.IsRainbow,
			preset.StripeColorMode,
			preset.IsEmptyCan
		)
	end
	
	-- "NEW" badge for unseen blocks
	if NewBlockIds[preset.Id] then
		addNewBadge(btn)
	end
	
	-- Long-press tracking for mobile drag-and-drop from creative grid
	local pressStartTime = nil
	local longPressFired = false
	local LONG_PRESS_TIME = 0.35 -- seconds
	
	btn.MouseButton1Down:Connect(function()
		pressStartTime = tick()
		longPressFired = false
		
		if IsMobile and not HeldItem then
			-- Start a long-press timer for mobile drag pickup
			local startTime = pressStartTime
			task.delay(LONG_PRESS_TIME, function()
				if pressStartTime == startTime and not longPressFired then
					longPressFired = true
					pickUpItem(preset.Id, preset.DefaultColor, nil)
				end
			end)
		end
	end)
	
	btn.MouseButton1Up:Connect(function()
		pressStartTime = nil
	end)
	
	btn.MouseButton1Click:Connect(function()
		if longPressFired then return end -- Already handled by long-press

		if HeldItem then
			-- Holding something: drop it (discard) into the creative grid
			HeldItem = nil
			if HeldItemFrame then
				HeldItemFrame:Destroy()
				HeldItemFrame = nil
			end
		else
			-- If a survival-style inventory is open (chest, furnace, etc.), pick up the item
			-- so the player can drag it around / transfer it. Otherwise, the default
			-- creative-tab behavior is to quick-add the block to the next available
			-- hotbar slot (replacing the current slot if the hotbar is full).
			local blockUIOpen = _G.BlockInteractionController and _G.BlockInteractionController.IsAnyBlockUIOpen and _G.BlockInteractionController.IsAnyBlockUIOpen()
			if blockUIOpen then
				pickUpItem(preset.Id, preset.DefaultColor, nil)
			elseif not IsMobile and (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)) then
				-- Shift-click on desktop = explicit pickup (for rearranging without opening a survival inventory)
				pickUpItem(preset.Id, preset.DefaultColor, nil)
			else
				-- Default click/tap: quick-add to hotbar
				addPresetToHotbar(preset.Id)
			end
		end
	end)
	
	-- Hover: lighten cell + show tooltip with block name
	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3 = Colors.CellHover
		if CategoryTooltip then
			CategoryTooltipText.Text = preset.Name
			local btnPos = btn.AbsolutePosition
			local btnSize = btn.AbsoluteSize
			CategoryTooltip.Position = UDim2.new(0, btnPos.X + btnSize.X / 2 - 40, 0, btnPos.Y + btnSize.Y + 4)
			CategoryTooltip.Visible = true
		end
	end)
	
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = Colors.CellBg
		if CategoryTooltip then
			CategoryTooltip.Visible = false
		end
	end)
	
	return btn
end

-- Check if a preset is a permanent tool
local function isPermanentTool(presetId)
	for _, permToolId in pairs(PermanentTools) do
		if permToolId == presetId then
			return true
		end
	end
	return false
end

-- Create a button for items from the Tools folder
local function createToolItemButton(tool, parent)
	local btnWidth = IsMobile and 58 or 64
	local btnHeight = IsMobile and 58 or 64
	
	local btn = Instance.new("TextButton")
	btn.Name = tool.Name
	btn.Size = UDim2.new(0, btnWidth, 0, btnHeight)
	btn.BackgroundColor3 = Colors.CellBg
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.Parent = parent
	
	addInsetBevel(btn)
	
	local viewport = createViewportPreview(btn, UDim2.new(1, -12, 1, -12))
	viewport.Position = UDim2.new(0, 6, 0, 6)
	
	-- Clone the tool into the viewport
	local worldModel = viewport:FindFirstChild("World")
	if worldModel then
		local model = tool:Clone()
		
		-- Tools render with the orientation they were authored in Studio (just
		-- face the camera). Tools authored at a diagonal will display at that diagonal.
		-- Parent the model FIRST, THEN set CFrame — UnionOperations in ViewportFrames
		-- sometimes don't refresh their rendered orientation if CFrame is set before parenting.
		local toolRotation = CFrame.Angles(0, math.rad(180), 0)
		model.Parent = worldModel
		if model:IsA("BasePart") then
			model.Anchored = true
			model.CFrame = CFrame.new(0, 0, 0) * toolRotation
		elseif model:IsA("Model") or model:IsA("Tool") then
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
				end
			end
			if model:IsA("Model") then
				model:PivotTo(CFrame.new(0, 0, 0) * toolRotation)
			elseif model:IsA("Tool") then
				local handle = model:FindFirstChild("Handle")
				if handle and handle:IsA("BasePart") then
					handle.CFrame = CFrame.new(0, 0, 0) * toolRotation
				end
			end
		end

		-- Camera looks straight at the flat face
		local camera = viewport.CurrentCamera
		if camera then
			camera.CFrame = CFrame.new(Vector3.new(0, 0, 5), Vector3.new(0, 0, 0))
		end
	end
	
	btn.MouseButton1Click:Connect(function()
		local slot = findFirstEmptySlot()
		if not slot then
			slot = CurrentSlot
		end
		
		Hotbar[slot] = {
			ToolName = tool.Name,
			IsTool = true,
		}
		
		updateHotbarSlotViewport(slot)
		selectSlot(slot)
		
		local slotFrame = SlotFrames[slot]
		if slotFrame then
			local original = slotFrame.BackgroundColor3
			slotFrame.BackgroundColor3 = Colors.Success
			task.delay(0.15, function()
				TweenService:Create(slotFrame, TweenInfo.new(0.2), {BackgroundColor3 = original}):Play()
			end)
		end
		
		print("[Tools] Added", tool.Name, "to hotbar slot", slot)
	end)
	
	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3 = Colors.CellHover
		if CategoryTooltip then
			CategoryTooltipText.Text = tool.Name
			local btnPos = btn.AbsolutePosition
			local btnSize = btn.AbsoluteSize
			CategoryTooltip.Position = UDim2.new(0, btnPos.X + btnSize.X / 2 - 40, 0, btnPos.Y + btnSize.Y + 4)
			CategoryTooltip.Visible = true
		end
	end)
	
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = Colors.CellBg
		if CategoryTooltip then
			CategoryTooltip.Visible = false
		end
	end)
	
	return btn
end

-- ============================================
-- SURVIVAL INVENTORY (persistent personal inventory)
-- ============================================

local function updateSurvivalSlotViewport(slotIndex)
	local slotFrame = SurvivalSlotFrames[slotIndex]
	if not slotFrame then return end
	
	-- Clear existing viewport
	local oldViewport = slotFrame:FindFirstChild("Viewport")
	if oldViewport then oldViewport:Destroy() end
	
	-- Update count label
	local countLabel = slotFrame:FindFirstChild("CountLabel")
	
	local data = SurvivalSlots[slotIndex]
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
	
	local preset = BlockPresets.GetPreset(data.p)
	if not preset then return end
	
	local color = nil
	if data.c and type(data.c) == "table" then
		color = Color3.fromRGB(data.c[1] or 255, data.c[2] or 255, data.c[3] or 255)
	elseif preset.Color then
		color = preset.Color
	end
	
	local viewport = createViewportPreview(slotFrame, UDim2.new(1, -6, 1, -6))
	viewport.Position = UDim2.new(0, 3, 0, 3)
	viewport.ZIndex = 4
	
	local shape = BlockPresets.GetShape(preset.Shape)
	if shape then
		setupViewportModel(
			viewport,
			shape.TemplateName,
			color,
			preset.Material,
			preset.MaterialVariant,
			preset.UseBlockModel,
			preset.BlockModelName,
			preset.IsDecoration,
			preset.DecorationName,
			preset.BlockModelFolder,
			preset.ApplyColor,
			preset.LeatherTint,
			preset.IsRainbow,
			preset.StripeColorMode
		)
	end
end

local function sendSurvivalSlotUpdate(slotIndex, itemData)
	if SurvivalRemotes.UpdateSurvivalSlot then
		SurvivalRemotes.UpdateSurvivalSlot:FireServer(slotIndex, itemData)
	end
end

local function onSurvivalSlotClick(slotIndex)
	local isHolding = HeldItem ~= nil
	local existingItem = SurvivalSlots[slotIndex]
	
	if isHolding then
		-- Drop held item into this survival slot
		local heldItem = HeldItem
		
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
			SurvivalSlots[slotIndex] = newItem
			updateSurvivalSlotViewport(slotIndex)
			sendSurvivalSlotUpdate(slotIndex, newItem)
			
			local existColor = nil
			if existingItem.c and type(existingItem.c) == "table" then
				existColor = Color3.fromRGB(existingItem.c[1] or 255, existingItem.c[2] or 255, existingItem.c[3] or 255)
			else
				local existPreset = BlockPresets.GetPreset(existingItem.p)
				if existPreset then existColor = existPreset.Color end
			end
			
			-- Discard and pick up existing
			HeldItem = nil
			if HeldItemFrame then HeldItemFrame:Destroy(); HeldItemFrame = nil end
			pickUpItem(existingItem.p, existColor, nil, existingItem.n or 1)
		else
			-- Empty slot: place the held item
			SurvivalSlots[slotIndex] = newItem
			updateSurvivalSlotViewport(slotIndex)
			sendSurvivalSlotUpdate(slotIndex, newItem)
			
			HeldItem = nil
			if HeldItemFrame then HeldItemFrame:Destroy(); HeldItemFrame = nil end
		end
		
		-- Flash feedback
		local slotFrame = SurvivalSlotFrames[slotIndex]
		if slotFrame then
			local original = slotFrame.BackgroundColor3
			slotFrame.BackgroundColor3 = Colors.Success
			task.delay(0.15, function()
				TweenService:Create(slotFrame, TweenInfo.new(0.2), {BackgroundColor3 = original}):Play()
			end)
		end
	else
		-- Not holding: pick up from this survival slot
		if existingItem and existingItem.p then
			local color = nil
			if existingItem.c and type(existingItem.c) == "table" then
				color = Color3.fromRGB(existingItem.c[1] or 255, existingItem.c[2] or 255, existingItem.c[3] or 255)
			else
				local preset = BlockPresets.GetPreset(existingItem.p)
				if preset then color = preset.Color end
			end
			
			SurvivalSlots[slotIndex] = nil
			updateSurvivalSlotViewport(slotIndex)
			sendSurvivalSlotUpdate(slotIndex, nil)
			
			pickUpItem(existingItem.p, color, nil, existingItem.n or 1)
		end
	end
end

local function onSurvivalSlotRightClick(slotIndex)
	local existingItem = SurvivalSlots[slotIndex]
	if existingItem and existingItem.p then
		SurvivalSlots[slotIndex] = nil
		updateSurvivalSlotViewport(slotIndex)
		sendSurvivalSlotUpdate(slotIndex, nil)
	end
end

local function createSurvivalGrid()
	-- Build the fixed 3x9 survival inventory grid as a sibling to PresetsContainer
	-- (Can't parent inside PresetsContainer because its UIGridLayout would override positioning)
	if SurvivalGridFrame then
		SurvivalGridFrame.Visible = true
		PresetsContainer.Visible = false
		-- Refresh all slot viewports
		for i = 1, SURVIVAL_SLOTS do
			updateSurvivalSlotViewport(i)
		end
		return
	end
	
	local SLOT_SIZE = IsMobile and 52 or 56
	local SLOT_PAD = 3
	local gridWidth = SURVIVAL_COLS * (SLOT_SIZE + SLOT_PAD) - SLOT_PAD
	local gridHeight = SURVIVAL_ROWS * (SLOT_SIZE + SLOT_PAD) - SLOT_PAD
	
	-- Outer container matches PresetsContainer position/size
	SurvivalGridFrame = Instance.new("Frame")
	SurvivalGridFrame.Name = "SurvivalGrid"
	SurvivalGridFrame.Position = PresetsContainer.Position
	SurvivalGridFrame.Size = PresetsContainer.Size
	SurvivalGridFrame.BackgroundColor3 = Colors.Background
	SurvivalGridFrame.BorderSizePixel = 0
	SurvivalGridFrame.ClipsDescendants = true
	SurvivalGridFrame.ZIndex = 2
	SurvivalGridFrame.Parent = InventoryPanel
	
	-- Inner grid centered within the container
	local innerGrid = Instance.new("Frame")
	innerGrid.Name = "InnerGrid"
	innerGrid.Size = UDim2.new(0, gridWidth, 0, gridHeight)
	innerGrid.AnchorPoint = Vector2.new(0.5, 0.5)
	innerGrid.Position = UDim2.new(0.5, 0, 0.5, 0)
	innerGrid.BackgroundTransparency = 1
	innerGrid.ZIndex = 3
	innerGrid.Parent = SurvivalGridFrame
	
	PresetsContainer.Visible = false
	
	SurvivalSlotFrames = {}
	
	for row = 0, SURVIVAL_ROWS - 1 do
		for col = 0, SURVIVAL_COLS - 1 do
			local slotIndex = row * SURVIVAL_COLS + col + 1
			
			local slot = Instance.new("TextButton")
			slot.Name = "SurvSlot_" .. slotIndex
			slot.Size = UDim2.new(0, SLOT_SIZE, 0, SLOT_SIZE)
			slot.Position = UDim2.new(0, col * (SLOT_SIZE + SLOT_PAD), 0, row * (SLOT_SIZE + SLOT_PAD))
			slot.BackgroundColor3 = Colors.CellBg
			slot.BorderSizePixel = 0
			slot.Text = ""
			slot.AutoButtonColor = false
			slot.ZIndex = 3
			slot.Parent = innerGrid
			
			addInsetBevel(slot)
			
			-- Count label
			local countLabel = Instance.new("TextLabel")
			countLabel.Name = "CountLabel"
			countLabel.Size = UDim2.new(0, 28, 0, 16)
			countLabel.Position = UDim2.new(1, -30, 1, -18)
			countLabel.BackgroundTransparency = 1
			countLabel.Text = ""
			countLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
			countLabel.TextSize = IsMobile and 12 or 14
			countLabel.Font = Enum.Font.GothamBold
			countLabel.TextXAlignment = Enum.TextXAlignment.Right
			countLabel.ZIndex = 6
			countLabel.Visible = false
			countLabel.Parent = slot
			
			local countStroke = Instance.new("UIStroke")
			countStroke.Color = Color3.fromRGB(30, 30, 30)
			countStroke.Thickness = 1.5
			countStroke.Parent = countLabel
			
			-- Hover
			slot.MouseEnter:Connect(function()
				slot.BackgroundColor3 = Colors.CellHover
				HoveredSurvivalSlot = slotIndex
			end)
			slot.MouseLeave:Connect(function()
				slot.BackgroundColor3 = Colors.CellBg
				if HoveredSurvivalSlot == slotIndex then
					HoveredSurvivalSlot = nil
				end
			end)
			
			-- Long-press for mobile
			local survPressStart = nil
			local survLongPressFired = false
			local SURV_LONG_PRESS_TIME = 0.35
			
			slot.MouseButton1Down:Connect(function()
				survPressStart = tick()
				survLongPressFired = false
				
				if IsMobile and not HeldItem then
					local startTime = survPressStart
					task.delay(SURV_LONG_PRESS_TIME, function()
						if survPressStart == startTime and not survLongPressFired then
							survLongPressFired = true
							local item = SurvivalSlots[slotIndex]
							if item and item.p then
								onSurvivalSlotClick(slotIndex)
							end
						end
					end)
				end
			end)
			
			slot.MouseButton1Up:Connect(function()
				survPressStart = nil
			end)
			
			slot.MouseButton1Click:Connect(function()
				if survLongPressFired then return end
				
				if IsMobile and not HeldItem then
					return -- Mobile: need long-press to pick up
				end
				
				-- Shift-click: quick-transfer to hotbar
				if not IsMobile and isShiftHeld() and not HeldItem then
					local item = SurvivalSlots[slotIndex]
					if item and item.p then
						if quickTransferToHotbar(item) then
							SurvivalSlots[slotIndex] = nil
							updateSurvivalSlotViewport(slotIndex)
							sendSurvivalSlotUpdate(slotIndex, nil)
						end
					end
					return
				end
				
				onSurvivalSlotClick(slotIndex)
			end)
			
			slot.MouseButton2Click:Connect(function()
				onSurvivalSlotRightClick(slotIndex)
			end)
			
			SurvivalSlotFrames[slotIndex] = slot
		end
	end
	
	-- Refresh viewports
	for i = 1, SURVIVAL_SLOTS do
		updateSurvivalSlotViewport(i)
	end
end

local function hideSurvivalGrid()
	if SurvivalGridFrame then
		SurvivalGridFrame.Visible = false
	end
	if PresetsContainer then
		PresetsContainer.Visible = true
	end
end

-- ============================================
-- SHIFT-CLICK QUICK TRANSFER
-- ============================================

-- Transfer an item into the first available hotbar slot
-- item: {p = "PresetId", c = {R,G,B} or nil, n = count}
quickTransferToHotbar = function(item)
	if not item or not item.p then return false end
	
	local preset = BlockPresets.GetPreset(item.p)
	if not preset then return false end
	
	local color = nil
	if item.c and type(item.c) == "table" then
		color = Color3.fromRGB(item.c[1] or 255, item.c[2] or 255, item.c[3] or 255)
	else
		color = preset.DefaultColor
	end
	
	local slot = findFirstEmptySlot()
	if not slot then
		slot = CurrentSlot -- Hotbar full, replace current
	end
	
	Hotbar[slot] = {
		PresetId = item.p,
		Color = color,
		Count = item.n or 1,
	}
	updateHotbarSlotViewport(slot)
	selectSlot(slot)
	
	-- Flash feedback
	local slotFrame = SlotFrames[slot]
	if slotFrame then
		local original = slotFrame.BackgroundColor3
		slotFrame.BackgroundColor3 = Colors.Success
		task.delay(0.15, function()
			TweenService:Create(slotFrame, TweenInfo.new(0.2), {BackgroundColor3 = original}):Play()
		end)
	end
	return true
end

-- Transfer an item into the first available survival slot
quickTransferToSurvival = function(item)
	if not item or not item.p then return false end
	
	for i = 1, SURVIVAL_SLOTS do
		if not SurvivalSlots[i] or not SurvivalSlots[i].p then
			SurvivalSlots[i] = { p = item.p, c = item.c, n = item.n }
			updateSurvivalSlotViewport(i)
			sendSurvivalSlotUpdate(i, SurvivalSlots[i])
			
			local slotFrame = SurvivalSlotFrames[i]
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

local function refreshPresetDisplay()
	-- Clear existing presets
	for _, child in ipairs(PresetsContainer:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	
	-- Handle Survival inventory tab (fixed grid, not scrollable presets)
	if SelectedCategory == "Inventory" then
		hideSurvivalGrid() -- Hide first so createSurvivalGrid re-shows cleanly
		createSurvivalGrid()
		
		-- Request data from server if not loaded yet
		if not SurvivalLoaded and SurvivalRemotes.RequestSurvivalInventory then
			SurvivalRemotes.RequestSurvivalInventory:FireServer()
		end
		return
	else
		hideSurvivalGrid()
	end
	
	local searchLower = CurrentSearchQuery:lower()
	local hasSearch = #searchLower > 0
	local layoutOrder = 0
	
	-- Check if a right tab is selected (Tools, Frames, etc.)
	if SelectedRightTab == "Tools" then
		-- Show items from Tools folder
		local hiddenTools = { ["WaterBucket"] = true, ["EmptyBucket"] = true, ["PaintBrush"] = true, ["PaintCan"] = true }
		if ToolsFolder then
			for _, tool in ipairs(ToolsFolder:GetChildren()) do
				if not hiddenTools[tool.Name] and (not hasSearch or tool.Name:lower():find(searchLower, 1, true)) then
					local btn = createToolItemButton(tool, PresetsContainer)
					btn.LayoutOrder = layoutOrder
					layoutOrder = layoutOrder + 1
				end
			end
		end
		return
	end
	
	if SelectedRightTab == "Frames" then
		-- Frames is a built-in right-tab. Show frame block presets from the Frames category.
		local framePresets = BlockPresets.GetPresetsByCategory("Frames")
		for _, preset in ipairs(framePresets) do
			if not hasSearch or preset.Name:lower():find(searchLower, 1, true) then
				local btn = createPresetButton(preset, PresetsContainer)
				btn.LayoutOrder = layoutOrder
				layoutOrder = layoutOrder + 1
			end
		end
		return
	end
	
	-- Themed-pack right-tabs (Candy, future Roman, etc). Same rendering as a normal
	-- left category — just routed through the right side. Locked blocks within the
	-- tab are still filtered by isPresetVisible below.
	if SelectedRightTab then
		local themedTabs = BlockPresets.GetThemedPackTabs and BlockPresets.GetThemedPackTabs() or {}
		for _, tab in ipairs(themedTabs) do
			if tab.Name == SelectedRightTab then
				local presets = BlockPresets.GetPresetsByCategory(SelectedRightTab)
				for _, preset in ipairs(presets) do
					if isPresetVisible(preset) and (not hasSearch or preset.Name:lower():find(searchLower, 1, true)) then
						local btn = createPresetButton(preset, PresetsContainer)
						btn.LayoutOrder = layoutOrder
						layoutOrder = layoutOrder + 1
					end
				end
				return
			end
		end
	end
	
	-- Normal block preset display
	-- Helper: check if a preset should be hidden (rainbow blocks require unlock)
	-- Owner check uses BetaConfig.OWNER_USER_ID (group-owned game; see top of file).
	-- Owner in /preview mode is treated as a fresh player so we can test the
	-- pre-unlock experience.
	local isOwnerRaw = (LocalPlayer.UserId == getOwnerUserId())
	local previewingAsFresh = isOwnerRaw and (LocalPlayer:GetAttribute("PreviewAsFresh") == true)
	local isCreator = isOwnerRaw and not previewingAsFresh
	local rainbowUnlocked = LocalPlayer:GetAttribute("RainbowBlocksUnlocked") or isCreator
	
	-- Helper: is this reward-gated preset unlocked for this player?
	local function isRewardUnlocked(preset)
		if not preset.IsRewardBlock then return true end
		if isCreator then return true end
		-- Variants share an unlock under BaseBlock; non-variants check by their own Id.
		local unlockKey = "Unlocked_" .. (preset.BaseBlock or preset.Id)
		return LocalPlayer:GetAttribute(unlockKey) == true
	end
	
	if hasSearch then
		-- Search across ALL categories
		for _, categoryData in ipairs(BlockPresets.GetAllCategories()) do
			local presets = BlockPresets.GetPresetsByCategory(categoryData.Name)
			for _, preset in ipairs(presets) do
				-- Skip rainbow blocks if not unlocked
				if preset.IsRainbow and not rainbowUnlocked then continue end
				-- Skip reward-set blocks if not unlocked
				if not isRewardUnlocked(preset) then continue end
				if not isPermanentTool(preset.Id) then
					local nameLower = preset.Name:lower()
					if nameLower:find(searchLower, 1, true) then
						local btn = createPresetButton(preset, PresetsContainer)
						btn.LayoutOrder = layoutOrder
						layoutOrder = layoutOrder + 1
					end
				end
			end
		end
	else
		-- Show selected category only
		local presets = BlockPresets.GetPresetsByCategory(SelectedCategory)
		for _, preset in ipairs(presets) do
			-- Skip rainbow blocks if not unlocked
			if preset.IsRainbow and not rainbowUnlocked then continue end
			-- Skip reward-set blocks if not unlocked
			if not isRewardUnlocked(preset) then continue end
			if not isPermanentTool(preset.Id) then
				local btn = createPresetButton(preset, PresetsContainer)
				btn.LayoutOrder = layoutOrder
				layoutOrder = layoutOrder + 1
			end
		end
	end
end

local function showCategory(categoryName)
	SelectedCategory = categoryName
	SelectedRightTab = nil -- Deselect right tab when selecting a left category
	
	-- Mark blocks in this category as seen on server (for "New" badge system)
	markTabBlocksSeen(categoryName)
	
	-- Clear search when switching categories
	if SearchBox then
		SearchBox.Text = ""
	end
	CurrentSearchQuery = ""
	
	refreshPresetDisplay()
	
	-- Update category button highlights (left side)
	if CategoryButtons then
		for catName, btn in pairs(CategoryButtons) do
			local bevelRight = btn:FindFirstChild("BevelRight")
			if catName == categoryName then
				-- Active tab: same color as panel so overlap blends seamlessly
				btn.BackgroundColor3 = Colors.Background
				if bevelRight then bevelRight.Visible = false end
			else
				-- Inactive tab: darker, panel covers inner edge
				btn.BackgroundColor3 = Colors.Surface
				if bevelRight then bevelRight.Visible = true end
			end
		end
	end
	
	-- Deselect right tabs
	for tabName, btn in pairs(RightTabButtons) do
		btn.BackgroundColor3 = Colors.Surface
		local bevelLeft = btn:FindFirstChild("BevelLeft")
		if bevelLeft then bevelLeft.Visible = true end
	end
end

local function showRightTab(tabName)
	SelectedRightTab = tabName
	SelectedCategory = nil -- Deselect left category
	
	-- Mark blocks in this tab as seen on server (for "New" badge system)
	markTabBlocksSeen(tabName)
	
	-- Clear search when switching tabs
	if SearchBox then
		SearchBox.Text = ""
	end
	CurrentSearchQuery = ""
	
	refreshPresetDisplay()
	
	-- Update right tab button highlights
	for tName, btn in pairs(RightTabButtons) do
		local bevelLeft = btn:FindFirstChild("BevelLeft")
		if tName == tabName then
			-- Active tab: same color as panel so overlap blends seamlessly
			btn.BackgroundColor3 = Colors.Background
			if bevelLeft then bevelLeft.Visible = false end
		else
			-- Inactive tab: darker, panel covers inner edge
			btn.BackgroundColor3 = Colors.Surface
			if bevelLeft then bevelLeft.Visible = true end
		end
	end
	
	-- Deselect left category buttons
	if CategoryButtons then
		for catName, btn in pairs(CategoryButtons) do
			btn.BackgroundColor3 = Colors.Surface
			local bevelRight = btn:FindFirstChild("BevelRight")
			if bevelRight then bevelRight.Visible = true end
		end
	end
end

local function createCategoryButton(categoryData, parent)
	-- Tab buttons (desktop wider so inner edge tucks under panel).
	-- Sized proportionally to the viewport icon so spacing stays consistent.
	local btnSize = IsMobile and 42 or 76
	local totalHeight = IsMobile and 42 or 56
	
	local btn = Instance.new("TextButton")
	btn.Name = categoryData.Name
	btn.Size = UDim2.new(0, btnSize, 0, totalHeight)
	btn.BackgroundColor3 = Colors.Surface
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = false
	btn.Parent = parent
	
	addBevel(btn)
	
	-- Viewport for the category icon
	local viewportSize = IsMobile and 30 or 48
	local viewport = createViewportPreview(btn, UDim2.new(0, viewportSize, 0, viewportSize))
	if IsMobile then
		viewport.Position = UDim2.new(0.5, -viewportSize/2, 0.5, -viewportSize/2)
	else
		-- Push icon to left (outer) edge so inner part tucks under panel
		viewport.Position = UDim2.new(0, 4, 0.5, -viewportSize/2)
	end
	
	-- Setup the icon model
	setupCategoryIconViewport(viewport, categoryData.IconBlock, categoryData.IconFolder)
	
	-- "!" notification badge if this category has new blocks
	if NewCategories[categoryData.Name] then
		addTabNotificationBadge(btn, "left")
	end
	
	-- No title labels on mobile (square icon-only tabs)
	
	btn.MouseButton1Click:Connect(function()
		showCategory(categoryData.Name)
	end)
	
	btn.MouseEnter:Connect(function()
		if SelectedCategory ~= categoryData.Name then
			TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Colors.SurfaceHover}):Play()
		end
		-- Show shared tooltip (desktop only, mobile has titles)
		if CategoryTooltip and not IsMobile then
			CategoryTooltipText.Text = categoryData.Name
			-- Position tooltip to the right of the button
			local btnPos = btn.AbsolutePosition
			local btnSizeAbs = btn.AbsoluteSize
			CategoryTooltip.Position = UDim2.new(0, btnPos.X + btnSizeAbs.X + 8, 0, btnPos.Y + btnSizeAbs.Y/2 - 12)
			CategoryTooltip.Visible = true
		end
	end)
	
	btn.MouseLeave:Connect(function()
		if SelectedCategory ~= categoryData.Name then
			TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Colors.Surface}):Play()
		end
		-- Hide shared tooltip
		if CategoryTooltip and not IsMobile then
			CategoryTooltip.Visible = false
		end
	end)
	
	return btn
end

local function createInventoryUI()
	-- Mobile-responsive inventory sizing
	-- Mobile: nearly full screen for better usability
	local panelWidth = IsMobile and 0.98 or 740
	local panelHeight = IsMobile and 0.85 or 460
	local panelSize = IsMobile and UDim2.new(panelWidth, 0, panelHeight, 0) or UDim2.new(0, panelWidth, 0, panelHeight)
	
	InventoryPanel = Instance.new("Frame")
	InventoryPanel.Name = "InventoryPanel"
	InventoryPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	InventoryPanel.Position = UDim2.new(0.5, 0, 0.45, 0)
	InventoryPanel.Size = panelSize
	InventoryPanel.BackgroundTransparency = 1
	InventoryPanel.BorderSizePixel = 0
	InventoryPanel.Visible = false
	InventoryPanel.ClipsDescendants = false
	InventoryPanel.Parent = ScreenGui
	
	-- Visible inner panel (narrower than full frame so tabs float outside)
	local PanelBg = Instance.new("Frame")
	PanelBg.Name = "PanelBackground"
	if IsMobile then
		-- Mobile: full width (tabs are small)
		PanelBg.Position = UDim2.new(0, 0, 0, 0)
		PanelBg.Size = UDim2.new(1, 0, 1, 0)
	else
		-- Desktop: starts after tab icon area, covers inner tab portion
		PanelBg.Position = UDim2.new(0, 58, 0, 0)
		PanelBg.Size = UDim2.new(1, -116, 1, 0)
	end
	PanelBg.BackgroundColor3 = Colors.Background
	PanelBg.BorderSizePixel = 0
	PanelBg.ZIndex = 1
	PanelBg.Parent = InventoryPanel
	
	addBevel(PanelBg)
	
	-- Hide left/right bevels on PanelBg so tabs connect flush
	if not IsMobile then
		local panelBevelLeft = PanelBg:FindFirstChild("BevelLeft")
		local panelBevelRight = PanelBg:FindFirstChild("BevelRight")
		if panelBevelLeft then panelBevelLeft.Visible = false end
		if panelBevelRight then panelBevelRight.Visible = false end
	end
	
	-- Shared MC-style tooltip (dark bg with purple highlight border)
	-- Outer frame acts as the purple border
	CategoryTooltip = Instance.new("Frame")
	CategoryTooltip.Name = "CategoryTooltip"
	CategoryTooltip.Size = UDim2.new(0, 0, 0, 0)
	CategoryTooltip.AutomaticSize = Enum.AutomaticSize.XY
	CategoryTooltip.BackgroundColor3 = Color3.fromRGB(16, 0, 16) -- Near-black outer
	CategoryTooltip.BorderSizePixel = 0
	CategoryTooltip.Visible = false
	CategoryTooltip.ZIndex = 100
	CategoryTooltip.Parent = ScreenGui
	
	-- Outer purple stroke (MC tooltip has 2-tone border)
	local tooltipStroke = Instance.new("UIStroke")
	tooltipStroke.Color = Color3.fromRGB(40, 0, 80)
	tooltipStroke.Thickness = 2
	tooltipStroke.Parent = CategoryTooltip
	
	-- Inner purple highlight edges (the signature MC tooltip gradient feel)
	local innerBorder = Instance.new("Frame")
	innerBorder.Name = "InnerBorder"
	innerBorder.Size = UDim2.new(1, -4, 1, -4)
	innerBorder.Position = UDim2.new(0, 2, 0, 2)
	innerBorder.BackgroundColor3 = Color3.fromRGB(16, 0, 16)
	innerBorder.BorderSizePixel = 0
	innerBorder.ZIndex = 101
	innerBorder.Parent = CategoryTooltip
	
	local innerStroke = Instance.new("UIStroke")
	innerStroke.Color = Color3.fromRGB(80, 0, 160) -- Brighter purple inner highlight
	innerStroke.Thickness = 1
	innerStroke.Parent = innerBorder
	
	-- Text label inside
	local tooltipText = Instance.new("TextLabel")
	tooltipText.Name = "TooltipText"
	tooltipText.Size = UDim2.new(0, 0, 0, 0)
	tooltipText.AutomaticSize = Enum.AutomaticSize.XY
	tooltipText.BackgroundTransparency = 1
	tooltipText.Text = ""
	tooltipText.TextColor3 = Color3.fromRGB(255, 255, 255)
	tooltipText.TextSize = 13
	tooltipText.Font = Enum.Font.Arcade
	tooltipText.ZIndex = 102
	tooltipText.Parent = innerBorder
	
	local tooltipPadding = Instance.new("UIPadding")
	tooltipPadding.PaddingLeft = UDim.new(0, 6)
	tooltipPadding.PaddingRight = UDim.new(0, 6)
	tooltipPadding.PaddingTop = UDim.new(0, 4)
	tooltipPadding.PaddingBottom = UDim.new(0, 4)
	tooltipPadding.Parent = innerBorder
	
	CategoryTooltipText = tooltipText -- Store reference for updating text

	-- Close button (top right, in line with search bar)
	local closeBtnSize = IsMobile and 32 or 28
	local closeBtn = Instance.new("TextButton")
	if IsMobile then
		-- Overlay close button on top-right of content area (inside grid bounds)
		closeBtn.Position = UDim2.new(1, -(60 + closeBtnSize + 8), 0, 10)
	else
		-- Position inside the visible PanelBg area
		closeBtn.Position = UDim2.new(1, -(58 + closeBtnSize + 10), 0, 10)
	end
	closeBtn.Size = UDim2.new(0, closeBtnSize, 0, closeBtnSize)
	closeBtn.BackgroundColor3 = Colors.Danger
	closeBtn.BorderSizePixel = 0
	closeBtn.Text = "X"
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.TextSize = IsMobile and 18 or 16
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.ZIndex = 10
	closeBtn.Parent = InventoryPanel
	
	addBevel(closeBtn)
	
	closeBtn.MouseButton1Click:Connect(closeInventory)
	
	-- Search bar (hidden on mobile to save space - categories work better)
	local searchFrame = Instance.new("Frame")
	searchFrame.Name = "SearchFrame"
	if IsMobile then
		-- Hide search on mobile
		searchFrame.Visible = false
		searchFrame.Position = UDim2.new(0, 10, 0, 52)
		searchFrame.Size = UDim2.new(1, -20, 0, 32)
	else
		searchFrame.Position = UDim2.new(0, 66, 0, 10)
		searchFrame.Size = UDim2.new(0, 240, 0, 28)
	end
	searchFrame.BackgroundColor3 = Colors.Surface
	searchFrame.BorderSizePixel = 0
	searchFrame.ZIndex = 2
	searchFrame.Parent = InventoryPanel
	
	addInsetBevel(searchFrame)
	
	local searchIcon = Instance.new("TextLabel")
	searchIcon.Name = "SearchIcon"
	searchIcon.Position = UDim2.new(0, 8, 0, 0)
	searchIcon.Size = UDim2.new(0, 24, 1, 0)
	searchIcon.BackgroundTransparency = 1
	searchIcon.Text = "🔍"
	searchIcon.TextColor3 = Colors.TextMuted
	searchIcon.TextSize = 14
	searchIcon.Font = Enum.Font.Arcade
	searchIcon.Parent = searchFrame
	
	SearchBox = Instance.new("TextBox")
	SearchBox.Name = "SearchBox"
	SearchBox.Position = UDim2.new(0, 32, 0, 0)
	SearchBox.Size = UDim2.new(1, -40, 1, 0)
	SearchBox.BackgroundTransparency = 1
	SearchBox.Text = ""
	SearchBox.PlaceholderText = "Search blocks..."
	SearchBox.PlaceholderColor3 = Colors.TextMuted
	SearchBox.TextColor3 = Colors.Text
	SearchBox.TextSize = 14
	SearchBox.Font = Enum.Font.Arcade
	SearchBox.TextXAlignment = Enum.TextXAlignment.Left
	SearchBox.ClearTextOnFocus = false
	SearchBox.Parent = searchFrame
	
	SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		CurrentSearchQuery = SearchBox.Text
		refreshPresetDisplay()
	end)
	
	-- Categories sidebar (square viewport buttons)
	-- On mobile: scrollable vertical sidebar on left with smaller buttons and titles
	local categoriesFrame
	if IsMobile then
		categoriesFrame = Instance.new("ScrollingFrame")
		categoriesFrame.Name = "Categories"
		categoriesFrame.Position = UDim2.new(0, 4, 0, 6)
		categoriesFrame.Size = UDim2.new(0, 56, 1, -12)
		categoriesFrame.BackgroundTransparency = 1
		categoriesFrame.ScrollBarThickness = 0 -- Hide scrollbar on mobile
		categoriesFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
		categoriesFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
		categoriesFrame.ScrollingDirection = Enum.ScrollingDirection.Y
		categoriesFrame.Parent = InventoryPanel
	else
		categoriesFrame = Instance.new("Frame")
		categoriesFrame.Name = "Categories"
		categoriesFrame.Position = UDim2.new(0, -8, 0, 38)
		categoriesFrame.Size = UDim2.new(0, 86, 1, -42)
		categoriesFrame.BackgroundTransparency = 1
		categoriesFrame.ZIndex = 0
		categoriesFrame.Parent = InventoryPanel
	end
	
	local catLayout = Instance.new("UIListLayout")
	catLayout.Padding = UDim.new(0, 4)
	catLayout.SortOrder = Enum.SortOrder.LayoutOrder -- Respect creation order
	-- Always vertical layout for categories
	catLayout.FillDirection = Enum.FillDirection.Vertical
	catLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	catLayout.VerticalAlignment = IsMobile and Enum.VerticalAlignment.Top or Enum.VerticalAlignment.Center
	catLayout.Parent = categoriesFrame
	
	CategoryButtons = {}
	
	-- Inventory tab (crafting table icon, above all other categories)
	local inventoryBtn = createCategoryButton({ Name = "Inventory", IconBlock = "CraftingTable", IconFolder = "BlockTemplates" }, categoriesFrame)
	inventoryBtn.LayoutOrder = -1
	CategoryButtons["Inventory"] = inventoryBtn

	-- Override icon viewport with proper crafting-table rendering using setupViewportModel.
	-- We mirror the OakCraftingTable preset's parameters so it renders identical to the
	-- crafting tables in the inventory grid.
	local invViewport = inventoryBtn:FindFirstChild("Viewport")
	if invViewport then
		local oakColor = Color3.fromRGB(240, 187, 135)
		local oakMaterial = Enum.Material.WoodPlanks
		local oakVariant = "PixelWoodPlanks"
		if BlocksFolder then
			local oakPlanks = BlocksFolder:FindFirstChild("OakPlanks")
			if oakPlanks then
				local pp = oakPlanks:IsA("BasePart") and oakPlanks or oakPlanks:FindFirstChildWhichIsA("BasePart")
				if pp then
					oakColor = pp.Color
					oakMaterial = pp.Material
					oakVariant = pp.MaterialVariant or oakVariant
				end
			end
		end
		local oakLeatherTint = Color3.fromRGB(165, 85, 38) -- Oak's leather tint from CraftingTableLeatherTints
		setupViewportModel(
			invViewport,
			"Block",
			oakColor,
			oakMaterial,
			oakVariant,
			false, -- UseBlockModel
			"CraftingTable",
			false, -- IsDecoration
			nil, -- DecorationName
			"BlockTemplates",
			true, -- ApplyColor
			oakLeatherTint
		)
	end
	
	local hiddenCategories = { ["Wiring"] = true, ["Items"] = true, ["Frames"] = true } -- Frames on right side, Wiring/Items hidden
	local layoutOrder = 0
	for _, categoryData in ipairs(BlockPresets.GetAllCategories()) do
		if not hiddenCategories[categoryData.Name] then
			local btn = createCategoryButton(categoryData, categoriesFrame)
			btn.LayoutOrder = layoutOrder
			layoutOrder = layoutOrder + 1
			CategoryButtons[categoryData.Name] = btn
		end
	end
	
	-- Right side tabs (Tools, etc.) - matches left side style
	local rightTabsFrame
	if IsMobile then
		rightTabsFrame = Instance.new("ScrollingFrame")
		rightTabsFrame.Name = "RightTabs"
		rightTabsFrame.Position = UDim2.new(1, -60, 0, 6)
		rightTabsFrame.Size = UDim2.new(0, 56, 1, -12)
		rightTabsFrame.BackgroundTransparency = 1
		rightTabsFrame.ScrollBarThickness = 0
		rightTabsFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
		rightTabsFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
		rightTabsFrame.ScrollingDirection = Enum.ScrollingDirection.Y
		rightTabsFrame.Parent = InventoryPanel
	else
		rightTabsFrame = Instance.new("Frame")
		rightTabsFrame.Name = "RightTabs"
		rightTabsFrame.Position = UDim2.new(1, -78, 0, 38)
		rightTabsFrame.Size = UDim2.new(0, 86, 1, -42)
		rightTabsFrame.BackgroundTransparency = 1
		rightTabsFrame.ZIndex = 0
		rightTabsFrame.Parent = InventoryPanel
	end
	
	local rightTabLayout = Instance.new("UIListLayout")
	rightTabLayout.Padding = UDim.new(0, 4)
	rightTabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rightTabLayout.FillDirection = Enum.FillDirection.Vertical
	rightTabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rightTabLayout.VerticalAlignment = IsMobile and Enum.VerticalAlignment.Top or Enum.VerticalAlignment.Center
	rightTabLayout.Parent = rightTabsFrame
	
	-- Create Tools tab button
	local function createRightTabButton(tabName, iconText, parent)
		local btnSize = IsMobile and 48 or 86
		local totalHeight = IsMobile and 48 or 64
		
		local btn = Instance.new("TextButton")
		btn.Name = tabName
		btn.Size = UDim2.new(0, btnSize, 0, totalHeight)
		btn.BackgroundColor3 = Colors.Surface
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.Parent = parent
		
		addBevel(btn)
		
		-- Icon (emoji or text)
		local iconLabel = Instance.new("TextLabel")
		iconLabel.Name = "Icon"
		if IsMobile then
			iconLabel.Position = UDim2.new(0, 0, 0, 4)
			iconLabel.Size = UDim2.new(1, 0, 0, 28)
		else
			-- Push icon to right (outer) edge
			iconLabel.Position = UDim2.new(0, 30, 0, 0)
			iconLabel.Size = UDim2.new(0, 56, 1, 0)
		end
		iconLabel.BackgroundTransparency = 1
		iconLabel.Text = iconText
		iconLabel.TextColor3 = Colors.Text
		iconLabel.TextSize = IsMobile and 20 or 26
		iconLabel.Font = Enum.Font.Arcade
		iconLabel.Parent = btn
		
		btn.MouseButton1Click:Connect(function()
			showRightTab(tabName)
		end)
		
		btn.MouseEnter:Connect(function()
			if SelectedRightTab ~= tabName then
				TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Colors.SurfaceHover}):Play()
			end
			if CategoryTooltip and not IsMobile then
				CategoryTooltipText.Text = tabName
				local btnPos = btn.AbsolutePosition
				local btnSizeAbs = btn.AbsoluteSize
				CategoryTooltip.Position = UDim2.new(0, btnPos.X - CategoryTooltip.AbsoluteSize.X - 8, 0, btnPos.Y + btnSizeAbs.Y/2 - 12)
				CategoryTooltip.Visible = true
			end
		end)
		
		btn.MouseLeave:Connect(function()
			if SelectedRightTab ~= tabName then
				TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Colors.Surface}):Play()
			end
			if CategoryTooltip and not IsMobile then
				CategoryTooltip.Visible = false
			end
		end)
		
		return btn
	end
	
	-- Create Tools tab button (special - uses viewport with shovel)
	local function createToolsTabButton(parent)
		local btnSize = IsMobile and 48 or 86
		local totalHeight = IsMobile and 48 or 64
		
		local btn = Instance.new("TextButton")
		btn.Name = "Tools"
		btn.Size = UDim2.new(0, btnSize, 0, totalHeight)
		btn.BackgroundColor3 = Colors.Surface
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.Parent = parent
		
		addBevel(btn)
		
		-- Viewport with shovel icon
		local viewportSize = IsMobile and 32 or 56
		local viewport = createViewportPreview(btn, UDim2.new(0, viewportSize, 0, viewportSize))
		if IsMobile then
			viewport.Position = UDim2.new(0.5, -viewportSize/2, 0, 4)
		else
			-- Push icon to right (outer) edge
			viewport.Position = UDim2.new(1, -(viewportSize + 4), 0.5, -viewportSize/2)
		end
		
		-- Add shovel to viewport (45° tilt, flat-face camera — matches hotbar/grid)
		if ToolsFolder then
			local shovelTemplate = ToolsFolder:FindFirstChild("Shovel")
			if shovelTemplate then
				local worldModel = viewport:FindFirstChild("World")
				if worldModel then
					local model = shovelTemplate:Clone()
					-- Tools render at authored orientation, just face camera (no extra tilt).
					local toolRotation = CFrame.Angles(0, math.rad(180), 0)
					if model:IsA("BasePart") then
						model.Anchored = true
						model.CFrame = CFrame.new(0, 0, 0) * toolRotation
					elseif model:IsA("Model") then
						for _, part in ipairs(model:GetDescendants()) do
							if part:IsA("BasePart") then
								part.Anchored = true
							end
						end
						model:PivotTo(CFrame.new(0, 0, 0) * toolRotation)
					end
					model.Parent = worldModel

					local camera = viewport.CurrentCamera
					if camera then
						camera.CFrame = CFrame.new(Vector3.new(0, 0, 5), Vector3.new(0, 0, 0))
					end
				end
			end
		end
		
		btn.MouseButton1Click:Connect(function()
			showRightTab("Tools")
		end)
		
		btn.MouseEnter:Connect(function()
			if SelectedRightTab ~= "Tools" then
				TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Colors.SurfaceHover}):Play()
			end
			-- Show tooltip (desktop only)
			if CategoryTooltip and not IsMobile then
				CategoryTooltipText.Text = "Tools"
				local btnPos = btn.AbsolutePosition
				local btnSizeAbs = btn.AbsoluteSize
				CategoryTooltip.Position = UDim2.new(0, btnPos.X - CategoryTooltip.AbsoluteSize.X - 8, 0, btnPos.Y + btnSizeAbs.Y/2 - 12)
				CategoryTooltip.Visible = true
			end
		end)
		
		btn.MouseLeave:Connect(function()
			if SelectedRightTab ~= "Tools" then
				TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Colors.Surface}):Play()
			end
			if CategoryTooltip and not IsMobile then
				CategoryTooltip.Visible = false
			end
		end)
		
		return btn
	end
	
	-- Add Frames tab (above Tools) - uses viewport with FrameBlock icon
	local function createFramesTabButton(parent)
		local btnSize = IsMobile and 48 or 86
		local totalHeight = IsMobile and 48 or 64
		
		local btn = Instance.new("TextButton")
		btn.Name = "Frames"
		btn.Size = UDim2.new(0, btnSize, 0, totalHeight)
		btn.BackgroundColor3 = Colors.Surface
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.Parent = parent
		
		addBevel(btn)
		
		-- Viewport with FrameBlock icon
		local viewportSize = IsMobile and 32 or 56
		local viewport = createViewportPreview(btn, UDim2.new(0, viewportSize, 0, viewportSize))
		if IsMobile then
			viewport.Position = UDim2.new(0.5, -viewportSize/2, 0, 4)
		else
			-- Push icon to right (outer) edge
			viewport.Position = UDim2.new(1, -(viewportSize + 4), 0.5, -viewportSize/2)
		end
		
		-- Add FrameBlock model to viewport (match standard inventory icon style)
		if FrameBlocksFolder then
			local frameTemplate = FrameBlocksFolder:FindFirstChild("FrameBlock")
			if frameTemplate then
				local worldModel = viewport:FindFirstChild("World")
				if worldModel then
					local model = frameTemplate:Clone()
					if model:IsA("BasePart") then
						model.Anchored = true
						model.CFrame = CFrame.new(0, 0, 0) -- Clear baked-in rotation, center at origin
					elseif model:IsA("Model") then
						for _, part in ipairs(model:GetDescendants()) do
							if part:IsA("BasePart") then
								part.Anchored = true
							end
						end
						model:PivotTo(CFrame.new(0, -1.5, 0))
					end
					model.Parent = worldModel
					
					local camera = viewport.CurrentCamera
					if camera then
						camera.CFrame = CFrame.new(Vector3.new(4.5, 3.6, 4.5), Vector3.new(0, 0, 0))
					end
				end
			end
		end
		
		btn.MouseButton1Click:Connect(function()
			showRightTab("Frames")
		end)
		
		btn.MouseEnter:Connect(function()
			if SelectedRightTab ~= "Frames" then
				TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Colors.SurfaceHover}):Play()
			end
			if CategoryTooltip and not IsMobile then
				CategoryTooltipText.Text = "Frames"
				local btnPos = btn.AbsolutePosition
				local btnSizeAbs = btn.AbsoluteSize
				CategoryTooltip.Position = UDim2.new(0, btnPos.X - CategoryTooltip.AbsoluteSize.X - 8, 0, btnPos.Y + btnSizeAbs.Y/2 - 12)
				CategoryTooltip.Visible = true
			end
		end)
		
		btn.MouseLeave:Connect(function()
			if SelectedRightTab ~= "Frames" then
				TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Colors.Surface}):Play()
			end
			if CategoryTooltip and not IsMobile then
				CategoryTooltip.Visible = false
			end
		end)
		
		return btn
	end
	
	-- Generic themed-pack tab button (Candy, future Roman, etc). The icon comes
	-- from the set's TabIcon model in RewardSets/<SetName>/<IconBlockName>.
	-- Mirrors createFramesTabButton's geometry/styling.
	local function createThemedPackTabButton(tabInfo, parent)
		local btnSize = IsMobile and 48 or 86
		local totalHeight = IsMobile and 48 or 64
		
		local btn = Instance.new("TextButton")
		btn.Name = tabInfo.Name
		btn.Size = UDim2.new(0, btnSize, 0, totalHeight)
		btn.BackgroundColor3 = Colors.Surface
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.Parent = parent
		
		addBevel(btn)
		
		local viewportSize = IsMobile and 32 or 56
		local viewport = createViewportPreview(btn, UDim2.new(0, viewportSize, 0, viewportSize))
		if IsMobile then
			viewport.Position = UDim2.new(0.5, -viewportSize/2, 0, 4)
		else
			viewport.Position = UDim2.new(1, -(viewportSize + 4), 0.5, -viewportSize/2)
		end
		
		-- Locate the icon model: RewardSets/<SetName>/<TabIcon or first block>
		local rewardSets = ReplicatedStorage:FindFirstChild("RewardSets")
		local setFolder = rewardSets and rewardSets:FindFirstChild(tabInfo.SetName)
		local iconTemplate = nil
		if setFolder then
			if tabInfo.IconBlockName then
				iconTemplate = setFolder:FindFirstChild(tabInfo.IconBlockName)
			end
			-- Fallback: first model in the set folder (skip the Manifest ModuleScript)
			if not iconTemplate then
				for _, child in ipairs(setFolder:GetChildren()) do
					if child:IsA("Model") or child:IsA("BasePart") then
						iconTemplate = child
						break
					end
				end
			end
		end
		
		if iconTemplate then
			local worldModel = viewport:FindFirstChild("World")
			if worldModel then
				local model = iconTemplate:Clone()
				if model:IsA("BasePart") then
					model.Anchored = true
					model.CFrame = CFrame.new(0, 0, 0)
				elseif model:IsA("Model") then
					for _, part in ipairs(model:GetDescendants()) do
						if part:IsA("BasePart") then
							part.Anchored = true
						end
					end
					-- Leave the model wherever its pivot puts it; the camera below frames
					-- to the model's real bounding-box center, so no pre-centering needed.
				end
				model.Parent = worldModel
				
				local camera = viewport.CurrentCamera
				if camera then
					-- Frame the camera to the model's actual size so any icon model
					-- (CandyBricks now, future Roman columns, etc.) fills the viewport
					-- uniformly instead of relying on a fixed distance tuned to a 3x3x3
					-- block. Distance = boundingRadius / sin(FOV/2), times a small pad.
					local radius = 2.6 -- fallback ~ half-diagonal of a 3-stud cube
					local center = Vector3.new(0, 0, 0)
					if model:IsA("Model") then
						local okb, bbCF, bbSize = pcall(function() return model:GetBoundingBox() end)
						if okb then
							radius = bbSize.Magnitude / 2
							center = bbCF.Position
						end
					elseif model:IsA("BasePart") then
						radius = model.Size.Magnitude / 2
						center = model.Position
					end
					local fov = math.rad(camera.FieldOfView)
					local dist = (radius / math.sin(fov / 2)) * 1.15 -- 1.15 = breathing room
					-- Same isometric view direction as before (down a (1, 0.8, 1) diagonal).
					local dir = Vector3.new(1, 0.8, 1).Unit
					camera.CFrame = CFrame.new(center + dir * dist, center)
				end
			end
		end
		
		btn.MouseButton1Click:Connect(function()
			showRightTab(tabInfo.Name)
		end)
		
		btn.MouseEnter:Connect(function()
			if SelectedRightTab ~= tabInfo.Name then
				TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Colors.SurfaceHover}):Play()
			end
			if CategoryTooltip and not IsMobile then
				CategoryTooltipText.Text = tabInfo.Name
				local btnPos = btn.AbsolutePosition
				local btnSizeAbs = btn.AbsoluteSize
				CategoryTooltip.Position = UDim2.new(0, btnPos.X - CategoryTooltip.AbsoluteSize.X - 8, 0, btnPos.Y + btnSizeAbs.Y/2 - 12)
				CategoryTooltip.Visible = true
			end
		end)
		
		btn.MouseLeave:Connect(function()
			if SelectedRightTab ~= tabInfo.Name then
				TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Colors.Surface}):Play()
			end
			if CategoryTooltip and not IsMobile then
				CategoryTooltip.Visible = false
			end
		end)
		
		return btn
	end
	
	local framesTabBtn = createFramesTabButton(rightTabsFrame)
	framesTabBtn.LayoutOrder = 0
	RightTabButtons["Frames"] = framesTabBtn
	if NewRightTabs["Frames"] then
		addTabNotificationBadge(framesTabBtn, "right")
	end
	
	-- Add Tools tab
	local toolsTabBtn = createToolsTabButton(rightTabsFrame)
	toolsTabBtn.LayoutOrder = 1
	RightTabButtons["Tools"] = toolsTabBtn
	
	-- Themed-pack tabs (Candy, future Roman, etc). Each tab is only shown if the
	-- player has unlocked at least one block from the set (owner sees them all,
	-- unless in /preview mode). The buttons are CREATED here but their .Visible
	-- property is toggled at startup AND whenever a relevant attribute changes,
	-- by refreshThemedPackTabVisibility() below.
	local ThemedPackTabButtons = {}  -- { [tabName] = button }
	local themedTabsLayoutStart = 2
	local themedTabsList = BlockPresets.GetThemedPackTabs and BlockPresets.GetThemedPackTabs() or {}
	for i, tabInfo in ipairs(themedTabsList) do
		local btn = createThemedPackTabButton(tabInfo, rightTabsFrame)
		btn.LayoutOrder = themedTabsLayoutStart + (i - 1)
		RightTabButtons[tabInfo.Name] = btn
		ThemedPackTabButtons[tabInfo.Name] = btn
		if NewRightTabs[tabInfo.Name] then
			addTabNotificationBadge(btn, "right")
		end
	end
	
	-- Apply initial visibility, plus a refresh on player attribute changes
	local function refreshThemedPackTabVisibility()
		for tabName, btn in pairs(ThemedPackTabButtons) do
			local shouldShow = isTabVisible(tabName)
			btn.Visible = shouldShow
			-- If the player is currently looking at a tab that just became hidden
			-- (e.g. they toggled /preview on), bounce them back to a safe default.
			if not shouldShow and SelectedRightTab == tabName then
				SelectedCategory = "Building"
				SelectedRightTab = nil
				refreshPresetDisplay()
			end
		end
	end
	refreshThemedPackTabVisibility()
	
	-- Listen for Rainbow Blocks unlock during session (daily reward claim, etc.)
	-- When unlocked, refresh the display so rainbow blocks appear in Colors tab
	LocalPlayer.AttributeChanged:Connect(function(attrName)
		if attrName == "RainbowBlocksUnlocked" and LocalPlayer:GetAttribute("RainbowBlocksUnlocked") then
			if SelectedCategory == "Colors" then
				refreshPresetDisplay()
			end
		end
		-- Reward-set block unlocks (Unlocked_<BlockId>) - refresh inventory so the new block appears
		if string.sub(attrName, 1, 9) == "Unlocked_" then
			refreshPresetDisplay()
			-- A new unlock may make a previously-hidden themed-pack tab appear.
			refreshThemedPackTabVisibility()
		end
		-- Owner preview toggle: re-evaluate the whole inventory's visibility.
		if attrName == "PreviewAsFresh" then
			refreshPresetDisplay()
			refreshThemedPackTabVisibility()
		end
	end)
	
	-- Presets container (responsive layout)
	PresetsContainer = Instance.new("ScrollingFrame")
	PresetsContainer.Name = "Presets"
	if IsMobile then
		-- Position between left and right sidebars
		PresetsContainer.Position = UDim2.new(0, 64, 0, 6)
		PresetsContainer.Size = UDim2.new(1, -128, 1, -12) -- Account for both sidebars
	else
		-- Desktop: leave room for right tabs
		PresetsContainer.Position = UDim2.new(0, 68, 0, 48)
		PresetsContainer.Size = UDim2.new(1, -136, 1, -57) -- inside PanelBg, matched bottom padding
	end
	PresetsContainer.BackgroundColor3 = Colors.Background
	PresetsContainer.BorderSizePixel = 0
	PresetsContainer.ClipsDescendants = true
	PresetsContainer.ZIndex = 2
	PresetsContainer.ScrollBarThickness = 0
	PresetsContainer.ScrollBarImageColor3 = Colors.TextMuted
	PresetsContainer.VerticalScrollBarInset = Enum.ScrollBarInset.None
	PresetsContainer.AutomaticCanvasSize = Enum.AutomaticSize.Y
	PresetsContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
	PresetsContainer.Parent = InventoryPanel
	
	-- Content area border overlay (inset bevel that stays fixed while content scrolls)
	local contentBorder = Instance.new("Frame")
	contentBorder.Name = "ContentBorder"
	contentBorder.Size = PresetsContainer.Size
	contentBorder.Position = PresetsContainer.Position
	contentBorder.BackgroundTransparency = 1
	contentBorder.ZIndex = 4
	contentBorder.Parent = InventoryPanel
	addInsetBevel(contentBorder)
	
	-- Square MC-style slot grid with tight padding
	local presetCellSize = IsMobile and 58 or 64
	local presetsLayout = Instance.new("UIGridLayout")
	presetsLayout.CellSize = UDim2.new(0, presetCellSize, 0, presetCellSize)
	presetsLayout.CellPadding = UDim2.new(0, 3, 0, 3)  -- Slightly more spacing for larger cells
	presetsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	presetsLayout.SortOrder = Enum.SortOrder.LayoutOrder -- Respect button LayoutOrder
	presetsLayout.Parent = PresetsContainer
	
	local presetsPadding = Instance.new("UIPadding")
	presetsPadding.PaddingTop = UDim.new(0, 6)
	presetsPadding.PaddingLeft = UDim.new(0, 6)
	presetsPadding.PaddingRight = UDim.new(0, 6)
	presetsPadding.PaddingBottom = UDim.new(0, 6)
	presetsPadding.Parent = PresetsContainer
	
	-- Show first category
	showCategory("Building")
end

--====================--
--      INPUT         --
--====================--

SlotFrames = {}

-- Get unified slot index (1-3 = tools, 4-13 = hotbar)
local function getUnifiedSlotIndex()
if IsToolSlotSelected then
return CurrentToolSlot -- 1, 2, or 3
else
return 3 + CurrentSlot -- 4 through 13
end
end

local TOTAL_UNIFIED = 3 + HOTBAR_SLOTS
local function selectUnifiedSlot(index)
-- Wrap around
if index < 1 then
index = TOTAL_UNIFIED
elseif index > TOTAL_UNIFIED then
index = 1
end
	
	if index <= 3 then
		-- Tool slot
		selectToolSlot(index)
	else
		-- Hotbar slot
		selectSlot(index - 3)
	end
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	
	-- Don't process hotkeys while any overlay is open
	if _G.SignEditController and _G.SignEditController.IsEditing and _G.SignEditController.IsEditing() then return end
	
	-- Don't toggle inventory if a block UI (chest/crafting/furnace) is open — E closes those instead
	if _G.BlockInteractionController and _G.BlockInteractionController.IsAnyBlockUIOpen and _G.BlockInteractionController.IsAnyBlockUIOpen() then return end
	
	if input.KeyCode == Enum.KeyCode.E then
		toggleInventory() -- openInventory already checks isAnyOverlayOpen()
	-- Main hotbar slots (1-0)
	elseif input.KeyCode == Enum.KeyCode.One then selectSlot(1)
	elseif input.KeyCode == Enum.KeyCode.Two then selectSlot(2)
	elseif input.KeyCode == Enum.KeyCode.Three then selectSlot(3)
	elseif input.KeyCode == Enum.KeyCode.Four then selectSlot(4)
	elseif input.KeyCode == Enum.KeyCode.Five then selectSlot(5)
	elseif input.KeyCode == Enum.KeyCode.Six then selectSlot(6)
	elseif input.KeyCode == Enum.KeyCode.Seven then selectSlot(7)
	elseif input.KeyCode == Enum.KeyCode.Eight then selectSlot(8)
	elseif input.KeyCode == Enum.KeyCode.Nine then selectSlot(9)
	elseif input.KeyCode == Enum.KeyCode.Zero then selectSlot(10)
	-- Q: in normal gameplay, clears the currently selected hotbar slot.
	-- In inventory, clears whichever survival slot the cursor is hovering over.
	-- Tool slots are protected since clearing a permanent tool would be a mistake.
	elseif input.KeyCode == Enum.KeyCode.Q then
		if InventoryOpen then
			if HoveredSurvivalSlot then
				local item = SurvivalSlots[HoveredSurvivalSlot]
				if item and item.p then
					local idx = HoveredSurvivalSlot
					SurvivalSlots[idx] = nil
					updateSurvivalSlotViewport(idx)
					sendSurvivalSlotUpdate(idx, nil)
				end
			end
		elseif not IsToolSlotSelected then
			if Hotbar[CurrentSlot] then
				Hotbar[CurrentSlot] = nil
				updateHotbarSlotViewport(CurrentSlot)
				updateSelection()
			end
		end
	-- Tool belt slots (Z, X) - only if tool belt is enabled
	elseif SHOW_TOOL_BELT and input.KeyCode == Enum.KeyCode.Z then selectToolSlot(2)
	elseif SHOW_TOOL_BELT and input.KeyCode == Enum.KeyCode.X then selectToolSlot(3)
	-- Rotate
	elseif input.KeyCode == Enum.KeyCode.R then rotateBlock()
	end
end)

-- Scroll wheel to cycle through slots
UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if InventoryOpen then return end -- Don't scroll slots when inventory is open
	
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		if SHOW_TOOL_BELT then
			-- Cycle through all 9 slots (3 tools + 6 hotbar)
			local currentIndex = getUnifiedSlotIndex()
			if input.Position.Z > 0 then
				selectUnifiedSlot(currentIndex - 1)
			else
				selectUnifiedSlot(currentIndex + 1)
			end
		else
			-- Only cycle through hotbar slots
			local newSlot = CurrentSlot
			if input.Position.Z > 0 then
				newSlot = CurrentSlot - 1
				if newSlot < 1 then newSlot = HOTBAR_SLOTS end
			else
				newSlot = CurrentSlot + 1
				if newSlot > HOTBAR_SLOTS then newSlot = 1 end
			end
			selectSlot(newSlot)
		end
	end
end)

--====================--
--       INIT         --
--====================--

createHotbarUI()
createInventoryUI()

-- Pre-load permanent tools into tool belt (only if tool belt is enabled)
local function initializePermanentTools()
	if not SHOW_TOOL_BELT then return end
	
	for slotNumber, presetId in pairs(PermanentTools) do
		local preset = BlockPresets.GetPreset(presetId)
		if preset then
			ToolBelt[slotNumber] = {
				PresetId = presetId,
				Color = preset.DefaultColor,
			}
			updateToolSlotViewport(slotNumber)
		end
	end
end

initializePermanentTools()

--====================--
-- MOBILE HOTBAR SWIPE--
--====================--

local function setupHotbarSwipe()
	if not IsMobile then return end
	if not HotbarFrame then return end
	
	local swipeStart = nil
	local swipeStartSlot = nil
	local SWIPE_THRESHOLD = 40 -- Pixels needed to trigger slot change
	
	HotbarFrame.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			swipeStart = input.Position.X
			swipeStartSlot = CurrentSlot
		end
	end)
	
	HotbarFrame.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch and swipeStart then
			local delta = input.Position.X - swipeStart
			local slotDelta = math.floor(-delta / SWIPE_THRESHOLD)
			local newSlot = math.clamp(swipeStartSlot + slotDelta, 1, 6)
			
			if newSlot ~= CurrentSlot then
				selectSlot(newSlot)
			end
		end
	end)
	
	HotbarFrame.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			swipeStart = nil
			swipeStartSlot = nil
		end
	end)
end

setupHotbarSwipe()

--====================--
--    MOBILE UI       --
--====================--

local function createMobileUI()
	-- Mobile UI is now handled by MobileControls.client.luau
	-- This prevents overlapping buttons
	return
end

createMobileUI()

-- ============================================
-- HELD ITEM CURSOR TRACKING
-- ============================================

RunService.RenderStepped:Connect(function()
	if HeldItemFrame and HeldItem then
		local mousePos = UserInputService:GetMouseLocation()
		HeldItemFrame.Position = UDim2.new(0, mousePos.X - 26, 0, mousePos.Y - 62)
	end
end)

-- Right-click to cancel held item while inventory is open
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not InventoryOpen or not HeldItem then return end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		cancelHeldItem()
	end
end)

--====================--
--   TOOL USE HANDLER --
--====================--

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local UseTool = Remotes and Remotes:WaitForChild("UseTool", 5)

-- Tool use state for continuous usage
local ToolRightMouseDown = false
local ToolHoldStart = 0
local ToolCooldown = 0
local TOOL_USE_RATE = 0.15 -- Time between continuous uses
local TOOL_HOLD_THRESHOLD = 0.25 -- Must hold this long before continuous use

local function getSelectedToolFromHotbar()
	-- Check if current hotbar slot has a tool
	local data = Hotbar[CurrentSlot]
	if data and data.IsTool then
		return data.ToolName
	end
	return nil
end

local function useToolOnBlock()
	local toolName = getSelectedToolFromHotbar()
	if not toolName then return false end
	if not UseTool then 
		warn("[Tools] UseTool remote not found")
		return false
	end
	
	-- Raycast from center of screen (crosshair) - same as block placement
	local viewportSize = Camera.ViewportSize
	local ray = Camera:ViewportPointToRay(viewportSize.X / 2, viewportSize.Y / 2)
	
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {LocalPlayer.Character}
	
	local result = workspace:Raycast(ray.Origin, ray.Direction * 100, raycastParams)
	
	if result and result.Instance then
		-- Find the block (could be a part inside a model)
		local targetBlock = result.Instance
		
		-- If it's part of a model, get the model
		if targetBlock.Parent and targetBlock.Parent:IsA("Model") and targetBlock.Parent:GetAttribute("BlockType") then
			targetBlock = targetBlock.Parent
		elseif targetBlock:GetAttribute("BlockType") == nil then
			-- Check if parent has BlockType
			local parent = targetBlock.Parent
			while parent and parent ~= workspace do
				if parent:GetAttribute("BlockType") then
					targetBlock = parent
					break
				end
				parent = parent.Parent
			end
		end
		
		-- Only proceed if we found a valid block
		if targetBlock:GetAttribute("BlockType") then
			UseTool:FireServer({
				ToolName = toolName,
				TargetBlock = targetBlock,
				TargetPosition = result.Position,
			})
			return true
		else
			return false
		end
	else
		return false
	end
end

-- Right-click handler for tools (initial press)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if InventoryOpen then return end
	
	-- Right mouse button
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		if getSelectedToolFromHotbar() then
			ToolRightMouseDown = true
			ToolHoldStart = tick()
			ToolCooldown = TOOL_USE_RATE -- Set cooldown so continuous use waits
			useToolOnBlock() -- Immediate first use
		end
	end
end)

-- Track when right mouse is released for tools
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		ToolRightMouseDown = false
	end
end)

-- Continuous tool use loop (runs every frame)
RunService.RenderStepped:Connect(function(deltaTime)
	-- Skip if inventory is open or no tool selected
	if InventoryOpen then
		ToolRightMouseDown = false
		return
	end
	
	-- Continuous tool use when holding right mouse button
	if ToolRightMouseDown and not IsMobile then
		local toolName = getSelectedToolFromHotbar()
		if toolName then
			local holdDuration = tick() - ToolHoldStart
			if holdDuration >= TOOL_HOLD_THRESHOLD then
				ToolCooldown = ToolCooldown - deltaTime
				if ToolCooldown <= 0 then
					useToolOnBlock()
					ToolCooldown = TOOL_USE_RATE
				end
			end
		else
			-- Tool was deselected, stop continuous use
			ToolRightMouseDown = false
		end
	end
end)

_G.InventoryController = {
	GetSelectedBlock = getSelectedBlock,
	GetCurrentSlot = function() return CurrentSlot end,
	GetCurrentToolSlot = function() return CurrentToolSlot end,
	IsToolSlotSelected = function() return IsToolSlotSelected end,
	GetRotation = function() return CurrentRotation end,
	IsInventoryOpen = function() return InventoryOpen end,
	IsMobile = function() return IsMobile end,
	GetSelectedTool = getSelectedToolFromHotbar,
	OpenInventory = openInventory,
	CloseInventory = closeInventory,
	RotateBlock = rotateBlock,
	SelectSlot = selectSlot,
	SelectToolSlot = selectToolSlot,
	UseToolOnBlock = useToolOnBlock,
	-- Drag-and-drop API (used by block UIs: chest, crafting table, furnace)
	PickUpItem = pickUpItem,
	DropItemOnSlot = dropItemOnSlot,
	CancelHeldItem = cancelHeldItem,
	GrantItem = grantItem,
	IsHolding = function() return HeldItem ~= nil end,
	GetHeldItem = function() return HeldItem end,
	DiscardHeld = function()
		HeldItem = nil
		if HeldItemFrame then
			HeldItemFrame:Destroy()
			HeldItemFrame = nil
		end
	end,
	-- Viewport helpers (used by block UIs to show block previews in slots)
	CreateViewportPreview = createViewportPreview,
	SetupViewportModel = setupViewportModel,
	-- Quick-transfer (shift-click support for chest/survival UIs)
	QuickTransferToHotbar = quickTransferToHotbar,
	-- Personal inventory API (for block UIs to embed inventory below their grid)
	GetSurvivalSlots = function() return SurvivalSlots end,
	GetSurvivalSlotCount = function() return SURVIVAL_SLOTS end,
	GetSurvivalCols = function() return SURVIVAL_COLS end,
	GetSurvivalRows = function() return SURVIVAL_ROWS end,
	SetSurvivalSlot = function(index, data)
		SurvivalSlots[index] = data
		updateSurvivalSlotViewport(index)
		sendSurvivalSlotUpdate(index, data)
	end,
	IsSurvivalLoaded = function() return SurvivalLoaded end,
	RequestSurvivalData = function()
		if not SurvivalLoaded and SurvivalRemotes.RequestSurvivalInventory then
			SurvivalRemotes.RequestSurvivalInventory:FireServer()
		end
	end,
	QuickTransferToSurvival = quickTransferToSurvival,
	OnSurvivalDataLoaded = function(callback)
		table.insert(SurvivalDataCallbacks, callback)
	end,
	-- Hotbar API (for block UIs that embed the hotbar row, e.g. ChestUI)
	-- Returns slot data in chest-compatible format: { p, c, n } for blocks,
	-- { isTool=true, toolName=... } for tool slots, or nil if empty.
	GetHotbarSize = function() return HOTBAR_SLOTS end,
	GetHotbarSlot = function(index)
		local data = Hotbar[index]
		if not data then return nil end
		if data.IsTool then
			return { isTool = true, toolName = data.ToolName }
		end
		local colorArray = nil
		if data.Color then
			colorArray = {
				math.floor(data.Color.R * 255 + 0.5),
				math.floor(data.Color.G * 255 + 0.5),
				math.floor(data.Color.B * 255 + 0.5),
			}
		end
		return { p = data.PresetId, c = colorArray, n = data.Count or 1 }
	end,
	-- Write a hotbar slot from chest-compatible format. Pass nil to clear.
	SetHotbarSlot = function(index, data)
		if not data then
			Hotbar[index] = nil
			updateHotbarSlotViewport(index)
			if index == CurrentSlot and not IsToolSlotSelected then updateSelection() end
			return
		end
		if data.isTool then
			Hotbar[index] = { IsTool = true, ToolName = data.toolName }
			updateHotbarSlotViewport(index)
			return
		end
		local color = nil
		if data.c and type(data.c) == "table" then
			color = Color3.fromRGB(data.c[1] or 255, data.c[2] or 255, data.c[3] or 255)
		else
			local preset = BlockPresets.GetPreset(data.p)
			if preset then color = preset.DefaultColor end
		end
		Hotbar[index] = {
			PresetId = data.p,
			Color = color,
			Count = data.n or 1,
		}
		updateHotbarSlotViewport(index)
		if index == CurrentSlot and not IsToolSlotSelected then updateSelection() end
	end,
	-- Show/hide the on-screen hotbar (and toolbelt if enabled). Used by ChestUI
	-- so it can embed its own hotbar row inside the chest panel.
	SetHotbarVisible = function(visible)
		if HotbarFrame then HotbarFrame.Visible = visible end
		if ToolBeltFrame then ToolBeltFrame.Visible = visible and SHOW_TOOL_BELT end
	end,
}

-- ============================================
-- SURVIVAL INVENTORY REMOTES
-- ============================================
task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotes then return end
	
	SurvivalRemotes.RequestSurvivalInventory = remotes:WaitForChild("RequestSurvivalInventory", 10)
	SurvivalRemotes.UpdateSurvivalSlot = remotes:WaitForChild("UpdateSurvivalSlot", 10)
	local SurvivalInventoryResponse = remotes:WaitForChild("SurvivalInventoryResponse", 10)
	
	if SurvivalInventoryResponse then
		SurvivalInventoryResponse.OnClientEvent:Connect(function(contents)
			if not contents or type(contents) ~= "table" then return end
			
			-- Load contents into local slot data
			for i = 1, SURVIVAL_SLOTS do
				local item = contents[i]
				if item and type(item) == "table" and item.p then
					SurvivalSlots[i] = item
				else
					SurvivalSlots[i] = nil
				end
			end
			
			SurvivalLoaded = true
			
			-- Refresh viewports if survival tab is currently showing
			if SelectedCategory == "Inventory" then
				for i = 1, SURVIVAL_SLOTS do
					updateSurvivalSlotViewport(i)
				end
			end
			
			-- Fire external callbacks (ChestUI, CraftingTableUI, etc.)
			for _, cb in ipairs(SurvivalDataCallbacks) do
				task.spawn(cb)
			end
			
			print("[SurvivalInventory] Loaded contents from server")
		end)
	end
end)

if IsMobile then
	print("InventoryController initialized (Mobile) - Tap 📦 to open inventory, 🔄 to rotate")
else
	print("InventoryController initialized (Desktop) - Press E for inventory, R to rotate, Q/Z/X for tools")
end

-- ============================================
-- NEW BLOCK BADGE INIT
-- Fetch new block IDs from server on join
-- ============================================

-- Helper: apply new block data to UI (shared by real + debug paths)
local function applyNewBlockBadges(newIds)
	if not newIds or #newIds == 0 then
		NewBlocksLoaded = true
		print("[BB-NEW] No new blocks (player is up to date)")
		return
	end
	
	-- Build set of new block IDs
	for _, id in ipairs(newIds) do
		NewBlockIds[id] = true
	end
	
	-- Compute which categories/tabs have new content
	computeNewCategoriesFromIds()
	
	NewBlocksLoaded = true
	print("[BB-NEW] Loaded", #newIds, "new block IDs")
	
	-- Refresh display to show badges (if inventory is already built)
	if PresetsContainer then
		refreshPresetDisplay()
	end
	
	-- Add "!" badges to existing category tab buttons
	if CategoryButtons then
		for catName, btn in pairs(CategoryButtons) do
			if NewCategories[catName] and not btn:FindFirstChild("NewNotification") then
				addTabNotificationBadge(btn, "left")
			end
		end
	end
	
	-- Add "!" badges to existing right tab buttons
	for tabName, btn in pairs(RightTabButtons) do
		if NewRightTabs[tabName] and not btn:FindFirstChild("NewNotification") then
			addTabNotificationBadge(btn, "right")
		end
	end
	
	-- Mark the default open tab (Building) as seen since it loads on first open
	if SelectedCategory then
		markTabBlocksSeen(SelectedCategory)
	end
end

task.spawn(function()
	if DEBUG_NEW_BLOCKS then
		-- DEBUG MODE: Inject fake "new" blocks from multiple categories
		-- Picks the 2nd preset from several categories so you see badges + tab dots
		warn("[BB-NEW] DEBUG MODE ACTIVE — injecting fake new blocks")
		local debugIds = {}
		local debugCategories = { "Nature", "Building", "Decoration", "Colors", "Lights" }
		for _, catName in ipairs(debugCategories) do
			local presets = BlockPresets.GetPresetsByCategory(catName)
			if presets then
				-- Grab the 2nd and 3rd preset in each category (skip the 1st so it's not the icon block)
				if presets[2] then table.insert(debugIds, presets[2].Id) end
				if presets[3] then table.insert(debugIds, presets[3].Id) end
			end
		end
		print("[BB-NEW] DEBUG: Injected", #debugIds, "fake new blocks")
		applyNewBlockBadges(debugIds)
		return
	end
	
	-- PRODUCTION: Fetch from server
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if not remotes then
		warn("[BB-NEW] Remotes folder not found")
		return
	end
	
	local GetNewBlocks = remotes:WaitForChild("GetNewBlocks", 10)
	MarkTabSeenRemote = remotes:WaitForChild("MarkTabSeen", 10)
	
	if not GetNewBlocks then
		warn("[BB-NEW] GetNewBlocks remote not found")
		return
	end
	
	local success, result = pcall(function()
		return GetNewBlocks:InvokeServer()
	end)
	
	if success and result and type(result) == "table" then
		applyNewBlockBadges(result)
	else
		NewBlocksLoaded = true
		print("[BB-NEW] No new blocks (player is up to date)")
	end
	
	-- Listen for mid-session new block pushes (shop purchase, daily reward, etc.)
	local NewBlocksAvailable = remotes:WaitForChild("NewBlocksAvailable", 10)
	if NewBlocksAvailable then
		NewBlocksAvailable.OnClientEvent:Connect(function(newIds)
			if type(newIds) == "table" and #newIds > 0 then
				print("[BB-NEW] Received", #newIds, "new blocks mid-session")
				applyNewBlockBadges(newIds)
			end
		end)
		print("[BB-NEW] Listening for mid-session new block pushes")
	end
end)

-- Paint Mod: per-brush loaded state. Paint is per-brush, so each brush's color lives on its
-- own slot and the icon renders from that (NOT the global attribute). We record a color onto a
-- brush ONLY when the player actually loads it from a can -- the server fires BrushLoadedFromCan
-- for that, and never for routine select-syncs. (Stamping on the raw attribute change was racy:
-- a select echo could land after CurrentSlot moved and recolor the wrong brush, which is what
-- made brushes swap colors when scrolling between them.)
task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	local BrushLoadedFromCan = remotes and remotes:WaitForChild("BrushLoadedFromCan", 10)
	if not BrushLoadedFromCan then return end
	BrushLoadedFromCan.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		if IsToolSlotSelected then return end
		local data = Hotbar[CurrentSlot]
		if not (data and data.PresetId == "PaintBrush") then return end
		-- Peel one brush off the (empty) stack and color it; leave the rest empty.
		splitLoadedPaintItem({
			BrushLoaded = true,
			Color = Color3.fromRGB(payload.r or 255, payload.g or 255, payload.b or 255),
			BrushIsPrimer = payload.isPrimer and true or false,
			BrushMode = payload.mode or "blend",
		})
	end)
end)

-- Paint Mod: per-swatch captured color. Mirrors the brush -- each swatch's color lives on its
-- own slot (rendered via swatchLoadedColor). When the player captures a color, the server fires
-- SwatchCapturedFromBlock; we split one swatch off the held stack and color it, leaving the rest
-- empty. (The global Swatch* attributes are still set server-side for the Paint Mixer to read.)
task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	local SwatchCapturedFromBlock = remotes and remotes:WaitForChild("SwatchCapturedFromBlock", 10)
	if not SwatchCapturedFromBlock then return end
	SwatchCapturedFromBlock.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		if IsToolSlotSelected then return end
		local data = Hotbar[CurrentSlot]
		if not (data and data.PresetId == "PaintSwatch") then return end
		splitLoadedPaintItem({
			SwatchLoaded = true,
			Color = Color3.fromRGB(payload.r or 255, payload.g or 255, payload.b or 255),
		})
	end)
end)
