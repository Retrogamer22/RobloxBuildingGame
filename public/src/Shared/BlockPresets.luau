--[[
	BlockPresets
	Dynamically generates presets from the Blocks and Decorations folders
	Creates Block + Stair + Slab variants for each block (except logs)
	Organized into Minecraft-style categories: Building, Nature, Decoration, Wiring, Items
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Import color palette for dynamic color generation
local ColorPalette = require(script.Parent.Config.ColorPalette)

-- Feature toggles (set to false to hide from inventory)
local SHOW_GLASS = true -- Enabled - simple directional placement

-- Shape templates (reference BlockTemplates folder)
local Shapes = {
	Block = { TemplateName = "Block", Offset = Vector3.new(0, 0, 0), CanRotate = false },
	Slab = { TemplateName = "Slab", Offset = Vector3.new(0, 0, 0), CanRotate = false }, -- SlabPlacement handles offset
	Stair = { TemplateName = "Stair", Offset = Vector3.new(0, 0, 0), CanRotate = true },
	StairInner = { TemplateName = "StairInnerCorner", Offset = Vector3.new(0, 0, 0), CanRotate = true },
	StairOuter = { TemplateName = "StairOuterCorner", Offset = Vector3.new(0, 0, 0), CanRotate = true },
	Arch = { TemplateName = "Arch", Offset = Vector3.new(0, 0, 0), CanRotate = true },
	ArchInner = { TemplateName = "ArchInner", Offset = Vector3.new(0, 0, 0), CanRotate = true },
	ArchOuter = { TemplateName = "ArchOuter", Offset = Vector3.new(0, 0, 0), CanRotate = true },
	ArchLarge = { TemplateName = "ArchLarge", Offset = Vector3.new(0, 0, 0), CanRotate = true },
	ArchLargeInner = { TemplateName = "ArchLargeInner", Offset = Vector3.new(0, 0, 0), CanRotate = true },
	ArchLargeOuter = { TemplateName = "ArchLargeOuter", Offset = Vector3.new(0, 0, 0), CanRotate = true },
	Decoration = { TemplateName = "Decoration", Offset = Vector3.new(0, 0, 0), CanRotate = false }, -- 45-degree default
}

-- ========================================
-- CATEGORY CLASSIFICATION
-- ========================================

-- Natural blocks (dirt, grass, sand, leaves, logs, etc.)
local NatureBlocks = {
	["Dirt"] = true,
	["GrassBlock"] = true,
	["Sand"] = true,
	["Sandstone"] = true,
	["Gravel"] = true,
	["PathBlock"] = true,
	["Leaves"] = true,
	["OakLog"] = true,
	["SpruceLog"] = true,
	["BirchLog"] = true,
	["Stone"] = true,
	["StoneFence"] = true,
	["HayBale"] = true,
	["SnowBlock"] = true,
	["SnowLayer"] = true,
}

-- Wiring blocks (pistons, buttons, plates, lamps, logic gates)
local WiringBlocks = {
	["Piston"] = true,
	["StickyPiston"] = true,
	["Inverter"] = true,
	["ORGate"] = true,
	["DelayGate"] = true,
}

-- Blocks/models that should NOT generate automatic presets (handled manually)
local SkipAutoPreset = {
	["TorchStraight"] = true,
	["TorchAngled"] = true,
	["Campfire"] = true,
	["Lantern"] = true,
	["Vine"] = true,
	["VineTrimmed"] = true,
	["VineTrimmedEnd"] = true,
	["ColumnTorch"] = true,
	-- Column pieces (manually registered as single "Column" preset)
	["ColumnSingle"] = true,
	["ColumnBottom"] = true,
	["ColumnTop"] = true,
	["Column"] = true,
	-- Architrave pieces (auto-connected, registered as single "Architrave" preset)
	["ArchitraveSingle"] = true,
	["ArchitraveSingleEnd"] = true,
	["ArchitraveSingleMiddle"] = true,
	["ArchitraveSingleCorner"] = true,
	-- Architrave vertical variants (Top/Bottom/Middle)
	["ArchitraveSingleTop"] = true,
	["ArchitraveSingleBottom"] = true,
	["ArchitraveSingleEndTop"] = true,
	["ArchitraveSingleEndBottom"] = true,
	["ArchitraveSingleEndMiddle"] = true,
	["ArchitraveSingleMiddleTop"] = true,
	["ArchitraveSingleMiddleBottom"] = true,
	["ArchitraveSingleMiddleMiddle"] = true,
	["ArchitraveSingleCornerTop"] = true,
	["ArchitraveSingleCornerBottom"] = true,
	["ArchitraveSingleCornerMiddle"] = true,
	-- Architrave filled area pieces (for future use)
	["ArchitraveCorner"] = true,
	["ArchitraveMiddle"] = true,
	["ArchitraveMiddleBottom"] = true,
	["ArchitraveFullMiddle"] = true,
	-- Chest (manually registered with wood variants)
	["SingleChest"] = true,
	-- Bed (manually registered with color variants)
	["Bed"] = true,
}

-- Blocks that exist but should be hidden from inventory (created by tools, etc.)
local HideFromInventoryBlocks = {
	["PathBlock"] = true, -- Created by shovel on grass
	["GrassSlab"] = true, -- Created by grass spread from DirtSlab
	["SnowyGrassBlock"] = true, -- Created when snow is placed on grass
	-- Column internal pieces (only ColumnSingle shown as "Column")
	["ColumnBottom"] = true,
	["ColumnTop"] = true,
	["Column"] = true,
}

-- Blocks that should go in Decoration category (value = SortPriority, or true for default)
local DecorationBlocks = {
	["Cactus"] = 150,
	["GlassBlock"] = 150,
	["Furnace"] = 208, -- Near chests and crafting tables
}

-- Blocks to skip when creating stair/slab variants
local SkipVariants = {
	-- Nature blocks
	["OakLog"] = true,
	["SpruceLog"] = true,
	["BirchLog"] = true,
	["OakLogHollow"] = true,
	["SpruceLogHollow"] = true,
	["BirchLogHollow"] = true,
	["Leaves"] = true,
	["GrassBlock"] = true,
	["SnowyGrassBlock"] = true,
	["PathBlock"] = true,
	-- Decoration blocks
	["Cactus"] = true,
	-- Glass blocks
	["GlassBlock"] = true,
	-- Grass slab (auto-converted, not player-placed)
	["GrassSlab"] = true,
	-- Misc full blocks
	["HayBale"] = true,
	["SnowBlock"] = true,
	["SnowLayer"] = true,
	-- Wiring/Redstone blocks
	["Piston"] = true,
	["StickyPiston"] = true,
	["Inverter"] = true,
	["ORGate"] = true,
	["DelayGate"] = true,
	-- Furnace (model block, no stair/slab variants)
	["Furnace"] = true,
	-- Doors and trap doors
	["OakDoor"] = true,
	["SpruceDoor"] = true,
	["BirchDoor"] = true,
	["TrapDoor"] = true,
	["OakTrapDoor"] = true,
	["SpruceTrapDoor"] = true,
	["BirchTrapDoor"] = true,
}

-- Pattern-based skip: blocks matching these patterns won't get stair/slab variants
-- This automatically handles new log types without needing to add them manually
local SkipVariantPatterns = {
	"Log",       -- Any log (OakLog, RedwoodLog, etc.)
	"LogHollow", -- Any hollow log
	"Door",      -- Any door (OakDoor, AcaciaDoor, TrapDoor, etc.)
}

-- Blocks that have CUSTOM Union models for stair/slab variants
-- These blocks will look for "Stair" and "Slab" Union children in their folder
-- instead of using auto-generated templates
local CustomVariantBlocks = {
	["CheckerboardTile"] = true,
	-- Add more blocks here that have custom Union stair/slab models
}

-- Check if a block should skip variants (by name or pattern)
local function shouldSkipVariants(blockName)
	-- Check explicit list first
	if SkipVariants[blockName] then
		return true
	end
	
	-- Check patterns
	for _, pattern in ipairs(SkipVariantPatterns) do
		if string.find(blockName, pattern) then
			return true
		end
	end
	
	return false
end

-- Check if a block has custom Union variants (stair/slab)
local function hasCustomVariants(blockName)
	return CustomVariantBlocks[blockName] == true
end

-- Blocks that are doors (special placement handling)
-- Now detected by pattern - any block with "Door" in the name
local DoorBlocks = {
	-- Populated dynamically during generatePresets()
}

-- Check if a block is a door (by name pattern)
local function isDoorBlock(blockName)
	return string.find(blockName, "Door") ~= nil
end

-- Blocks that are fences (auto-connecting) - populated dynamically
local FenceBlocks = {}

-- Blocks that are ladders (side-placement only) - populated dynamically
local LadderBlocks = {}

-- Blocks that are standing signs (top-only, 16-direction rotation) - populated dynamically
local SignStandingBlocks = {}

-- Blocks that are wall signs (side-only placement) - populated dynamically
local WallSignBlocks = {}

-- Will be populated during generatePresets() for all wood + stone types

-- Blocks that are crates (wood-colored crate blocks) - populated dynamically
local CrateBlocks = {}

-- Blocks that are beds (colored sheet variants) - populated dynamically
local BedBlocks = {}

-- Blocks that are chests (wood-colored chest models) - populated dynamically
local ChestBlocks = {}

-- Blocks that are crafting tables (wood-colored with leather tint) - populated dynamically
local CraftingTableBlocks = {}

-- Leather tint colors per wood type for crafting table overlays
-- Rich saturated hues, inspired by MC texture pack style crafting tables
local CraftingTableLeatherTints = {
	Oak = Color3.fromRGB(165, 85, 38),         -- Warm reddish-brown (classic OG MC crafting table)
	Spruce = Color3.fromRGB(120, 45, 40),      -- Deep wine/maroon (rich & dark against dark spruce)
	Birch = Color3.fromRGB(140, 80, 42),       -- Rich warm saddle brown (classic leather against pale birch)
	Acacia = Color3.fromRGB(185, 70, 35),      -- Bold burnt orange-red (fiery, distinct from orange wood)
	DarkOak = Color3.fromRGB(165, 50, 35),     -- Warm crimson-red (bold contrast against dark wood)
	Ebony = Color3.fromRGB(195, 155, 40),      -- Bright gold (strong contrast against near-black)
	Redwood = Color3.fromRGB(140, 50, 45),     -- Deep burgundy/wine red (warm but distinct from red wood)
}

-- Frame blocks (wireframe blocks that can be filled with material)
local FrameBlocks = {}

-- Blocks that are glass panes (auto-connecting)
local GlassBlocks = {
	["Glass"] = true,
}

-- Blocks that are torches (special placement - straight on top, angled on sides)
local TorchBlocks = {
	["Torch"] = true,
}

-- Blocks that are campfires (placed on top of blocks only, has smoke particles)
local CampfireBlocks = {
	["Campfire"] = true,
	["ColumnTorch"] = true,
}

-- Blocks that are columns (vertical stacking with dynamic top/middle/bottom)
local ColumnBlocks = {
	["Column"] = true,
}

-- Blocks that are lanterns (placed on top or bottom of blocks only)
local LanternBlocks = {
	["Lantern"] = true,
}

-- Blocks that are architraves (auto-connecting decorative molding)
local ArchitraveBlocks = {
	["Architrave"] = true,
}

-- Blocks that are glowstone (light-emitting colored blocks) - populated dynamically
local GlowstoneBlocks = {}

-- Saplings (grow into trees)
-- Maps sapling ID to tree type
local SaplingBlocks = {
	["OakSapling"] = "Oak",
	["SpruceSapling"] = "Spruce",
	["BirchSapling"] = "Birch",
	["AcaciaSapling"] = "Acacia",
	["DarkOakSapling"] = "DarkOak",
	["EbonySapling"] = "Ebony",
	["RedwoodSapling"] = "Redwood",
}

-- Placement restrictions for decorations
-- Maps decoration ID to a table of block types it can be placed on
-- Uses pattern matching: "Dirt" matches "Dirt", "GrassBlock" matches "GrassBlock", etc.
local DecorationPlacementRestrictions = {
	-- Grass decorations: only on dirt or grass blocks
	["TallGrass"] = { "Dirt", "GrassBlock" },
	["ShortGrass"] = { "Dirt", "GrassBlock" },
	
	-- Flowers: only on dirt or grass blocks
	["OrangeFlower"] = { "Dirt", "GrassBlock" },
	["PinkFlower"] = { "Dirt", "GrassBlock" },
	["RedFlower"] = { "Dirt", "GrassBlock" },
	["WhiteFlower"] = { "Dirt", "GrassBlock" },
	
	-- Sugar cane: dirt, grass, or sand
	["SugarCane"] = { "Dirt", "GrassBlock", "Sand", "SugarCane" },
	
	-- Saplings: only on dirt or grass blocks
	["OakSapling"] = { "Dirt", "GrassBlock" },
	["SpruceSapling"] = { "Dirt", "GrassBlock" },
	["BirchSapling"] = { "Dirt", "GrassBlock" },
	["AcaciaSapling"] = { "Dirt", "GrassBlock" },
	["DarkOakSapling"] = { "Dirt", "GrassBlock" },
	["EbonySapling"] = { "Dirt", "GrassBlock" },
	["RedwoodSapling"] = { "Dirt", "GrassBlock" },
}

-- Color palette for customization
local Colors = {
	Color3.fromRGB(255, 255, 255), -- White
	Color3.fromRGB(200, 200, 200), -- Light Gray
	Color3.fromRGB(128, 128, 128), -- Gray
	Color3.fromRGB(64, 64, 64),    -- Dark Gray
	Color3.fromRGB(27, 42, 53),    -- Black
	Color3.fromRGB(255, 0, 0),     -- Red
	Color3.fromRGB(255, 85, 0),    -- Orange
	Color3.fromRGB(255, 200, 0),   -- Yellow
	Color3.fromRGB(0, 200, 0),     -- Green
	Color3.fromRGB(0, 255, 255),   -- Cyan
	Color3.fromRGB(0, 128, 255),   -- Light Blue
	Color3.fromRGB(0, 0, 255),     -- Blue
	Color3.fromRGB(128, 0, 255),   -- Purple
	Color3.fromRGB(255, 0, 255),   -- Magenta
	Color3.fromRGB(255, 128, 180), -- Pink
	Color3.fromRGB(139, 90, 43),   -- Brown
	Color3.fromRGB(180, 130, 70),  -- Tan
	Color3.fromRGB(60, 40, 25),    -- Dark Brown
	Color3.fromRGB(0, 100, 0),     -- Dark Green
	Color3.fromRGB(0, 64, 128),    -- Navy
}

-- Extract color, material, and materialVariant from a block model
local function extractBlockProperties(blockModel)
	local color = Color3.fromRGB(128, 128, 128)
	local material = Enum.Material.Plastic
	local materialVariant = "" -- Empty string means no variant
	
	-- Find the first visible BasePart to get color/material/materialVariant
	local function checkPart(part)
		if part:IsA("BasePart") and part.Transparency < 1 then
			return part.Color, part.Material, part.MaterialVariant
		end
		return nil, nil, nil
	end
	
	if blockModel:IsA("BasePart") then
		color, material, materialVariant = checkPart(blockModel)
	elseif blockModel:IsA("Model") then
		-- Try to find a main part (prefer parts that aren't named "Grass" for GrassBlock, etc.)
		for _, part in ipairs(blockModel:GetDescendants()) do
			if part:IsA("BasePart") and part.Transparency < 1 then
				-- Skip top faces for multi-textured blocks
				if part.Name ~= "Grass" and part.Name ~= "Top" then
					color = part.Color
					material = part.Material
					materialVariant = part.MaterialVariant or ""
					break
				end
			end
		end
		
		-- Fallback: just use any visible part
		if color == Color3.fromRGB(128, 128, 128) then
			for _, part in ipairs(blockModel:GetDescendants()) do
				local c, m, mv = checkPart(part)
				if c then
					color, material, materialVariant = c, m, mv or ""
					break
				end
			end
		end
	end
	
	return color, material, materialVariant or ""
end

-- Format block name for display (add spaces before capitals)
local function formatName(name)
	-- Add space before capital letters (except first)
	local formatted = name:gsub("(%l)(%u)", "%1 %2")
	return formatted
end

-- Determine category for a block
local function getBlockCategory(blockName, isDoorBlock)
	-- Check for Log blocks first (pattern-based)
	if string.find(blockName, "Log") then
		return "Nature"
	end
	
	if NatureBlocks[blockName] then
		return "Nature"
	elseif WiringBlocks[blockName] then
		return "Wiring"
	elseif DecorationBlocks[blockName] then
		return "Decoration"
	elseif isDoorBlock then
		return "Building" -- Doors go in Building
	else
		return "Building" -- Default: processed/crafted blocks
	end
end

-- Generate presets from Blocks and Decorations folders
local function generatePresets()
	local presets = {}
	local blocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)
	local decorationsFolder = ReplicatedStorage:WaitForChild("Decorations", 10)
	
	if not blocksFolder then
		warn("[BlockPresets] Blocks folder not found!")
	end
	
	-- ========================================
	-- BLOCKS
	-- ========================================
	if blocksFolder then
		local blockNames = {}
		for _, block in ipairs(blocksFolder:GetChildren()) do
			table.insert(blockNames, block.Name)
		end
		table.sort(blockNames)
		
		for _, blockName in ipairs(blockNames) do
			local blockModel = blocksFolder:FindFirstChild(blockName)
			if not blockModel then continue end
			
			-- Skip models that are handled manually (torches, campfires, etc.)
			if SkipAutoPreset[blockName] then continue end
			
			local color, material, materialVariant = extractBlockProperties(blockModel)
			local displayName = formatName(blockName)
			
			-- Check if this is a door block (by pattern)
			local isDoor = isDoorBlock(blockName)
			if isDoor then
				DoorBlocks[blockName] = true -- Add to lookup table
			end
			
			-- Determine category
			local category = getBlockCategory(blockName, isDoor)
			
			-- Main block preset (uses actual model from Blocks folder)
			local decoSort = DecorationBlocks[blockName]
			table.insert(presets, {
				Id = blockName,
				Name = displayName,
				Category = category,
				Shape = "Block",
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = true, -- Flag to use model from Blocks folder
				BlockModelName = blockName,
				IsDoor = isDoor or nil, -- Flag for special door placement
				BaseBlock = blockName, -- Reference to base block for variants
				HideFromInventory = HideFromInventoryBlocks[blockName] or nil, -- Hide certain blocks
				SortPriority = type(decoSort) == "number" and decoSort or nil, -- Custom sort for decoration blocks
			})
			
			-- Stair and Slab variants (skip logs, doors, wiring, and special blocks)
			if not shouldSkipVariants(blockName) and not isDoor then
				-- Variants inherit category from base block if it's Nature
				local variantCategory = NatureBlocks[blockName] and "Nature" or "Building"
				
				-- Check if this block has custom Union variants
				if hasCustomVariants(blockName) then
					-- Look for Stair Union in the block folder
					local stairUnion = blockModel:FindFirstChild("Stair")
					if stairUnion then
						table.insert(presets, {
							Id = blockName .. "Stair",
							Name = displayName .. " Stair",
							Category = variantCategory,
							Shape = "Stair",
							Material = material,
							MaterialVariant = materialVariant,
							DefaultColor = color,
							UseBlockModel = true, -- Use the custom Union model
							BlockModelName = blockName,
							CustomVariantChild = "Stair", -- Child name to use from block folder
							BaseBlock = blockName,
						})
					end
					
					-- Look for Slab Union in the block folder
					local slabUnion = blockModel:FindFirstChild("Slab")
					if slabUnion then
						table.insert(presets, {
							Id = blockName .. "Slab",
							Name = displayName .. " Slab",
							Category = variantCategory,
							Shape = "Slab",
							Material = material,
							MaterialVariant = materialVariant,
							DefaultColor = color,
							UseBlockModel = true, -- Use the custom Union model
							BlockModelName = blockName,
							CustomVariantChild = "Slab", -- Child name to use from block folder
							BaseBlock = blockName,
						})
					end
				else
					-- Auto-generate stair/slab using templates
					-- Stair variant
					table.insert(presets, {
						Id = blockName .. "Stair",
						Name = displayName .. " Stair",
						Category = variantCategory,
						Shape = "Stair",
						Material = material,
						MaterialVariant = materialVariant,
						DefaultColor = color,
						UseBlockModel = false,
						BaseBlock = blockName, -- Reference to base block
					})
					
					-- Slab variant
					table.insert(presets, {
						Id = blockName .. "Slab",
						Name = displayName .. " Slab",
						Category = variantCategory,
						Shape = "Slab",
						Material = material,
						MaterialVariant = materialVariant,
						DefaultColor = color,
						UseBlockModel = false,
						BaseBlock = blockName, -- Reference to base block
					})
				end
			end
		end
	end
	
	-- ========================================
	-- CONCRETE (colored blocks -> Colors category)
	-- ========================================
	local concreteFolder = ReplicatedStorage:FindFirstChild("Concrete")
	if concreteFolder then
		local concreteNames = {}
		for _, concrete in ipairs(concreteFolder:GetChildren()) do
			table.insert(concreteNames, concrete.Name)
		end
		table.sort(concreteNames)
		
		for _, concreteName in ipairs(concreteNames) do
			local concreteModel = concreteFolder:FindFirstChild(concreteName)
			if not concreteModel then continue end
			
			local color, material, materialVariant = extractBlockProperties(concreteModel)
			
			-- Format display name: "BlueConcrete" -> "Blue Concrete"
			local displayName = concreteName:gsub("Concrete", " Concrete")
			-- Add space before capitals for names like "LightBlue"
			displayName = displayName:gsub("(%l)(%u)", "%1 %2")
			
			-- Main block preset
			table.insert(presets, {
				Id = concreteName,
				Name = displayName,
				Category = "Colors",
				Shape = "Block",
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = true,
				BlockModelName = concreteName,
				BlockModelFolder = "Concrete",
				BaseBlock = concreteName,
			})
			
			-- Stair variant
			table.insert(presets, {
				Id = concreteName .. "Stair",
				Name = displayName .. " Stair",
				Category = "Colors",
				Shape = "Stair",
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = false,
				BaseBlock = concreteName,
			})
			
			-- Slab variant
			table.insert(presets, {
				Id = concreteName .. "Slab",
				Name = displayName .. " Slab",
				Category = "Colors",
				Shape = "Slab",
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = false,
				BaseBlock = concreteName,
			})
			
			-- Fence variant
			local fenceId = concreteName .. "Fence"
			FenceBlocks[fenceId] = true
			table.insert(presets, {
				Id = fenceId,
				Name = displayName .. " Fence",
				Category = "Colors",
				Shape = "Block",
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = false,
				BlockModelFolder = "BlockTemplates",
				BlockModelName = "FenceMiddle",
				IsFence = true,
				ApplyColor = true,
				BaseBlock = concreteName,
			})
			
			-- Ladder variant
			local ladderId = concreteName .. "Ladder"
			LadderBlocks[ladderId] = true
			table.insert(presets, {
				Id = ladderId,
				Name = displayName .. " Ladder",
				Category = "Colors",
				Shape = "Block",
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = false, -- Must be false so SaveManager applies color on load
				BlockModelFolder = "BlockTemplates",
				BlockModelName = "Ladder",
				IsLadder = true,
				ApplyColor = true,
				BaseBlock = concreteName,
			})
		end
	else
		warn("[BlockPresets] Concrete folder not found!")
	end
	
	-- ========================================
	-- WOOL (colored wool blocks using concrete colors -> Decoration category)
	-- ========================================
	local woolBlockTemplates = ReplicatedStorage:FindFirstChild("BlockTemplates")
	local woolTemplate = woolBlockTemplates and woolBlockTemplates:FindFirstChild("Wool")
	if woolTemplate and concreteFolder then
		local _, woolMaterial, woolMaterialVariant = extractBlockProperties(woolTemplate)
		
		local woolNames = {}
		for _, concrete in ipairs(concreteFolder:GetChildren()) do
			table.insert(woolNames, concrete.Name)
		end
		table.sort(woolNames)
		
		for _, concreteName in ipairs(woolNames) do
			local concreteModel = concreteFolder:FindFirstChild(concreteName)
			if not concreteModel then continue end
			
			local color = extractBlockProperties(concreteModel)
			
			-- Override colors that don't work well with wool texture
			if concreteName == "WhiteConcrete" then
				color = Color3.fromRGB(255, 255, 255) -- Concrete white is too gray
			elseif concreteName == "LightBlueConcrete" then
				color = Color3.fromRGB(75, 155, 170) -- Darken so texture shows through
			elseif concreteName == "LightGreenConcrete" then
				color = Color3.fromRGB(100, 180, 65) -- Slightly darkened so texture shows through
			elseif concreteName == "BlackConcrete" then
				color = Color3.fromRGB(35, 35, 35) -- Lighten so texture is still visible
			end
			
			-- "BlueConcrete" -> "Blue" -> "Blue Wool"
			local colorName = concreteName:gsub("Concrete", "")
			local displayName = colorName:gsub("(%l)(%u)", "%1 %2") .. " Wool"
			local woolId = colorName .. "Wool"
			
			table.insert(presets, {
				Id = woolId,
				Name = displayName,
				Category = "Decoration",
				Shape = "Block",
				Material = woolMaterial,
				MaterialVariant = woolMaterialVariant,
				DefaultColor = color,
				UseBlockModel = false,
				BlockModelFolder = "BlockTemplates",
				BlockModelName = "Wool",
				ApplyColor = true,
				BaseBlock = woolId,
				SortPriority = 300, -- Group wool together at end of Decoration tab (after torch/campfire/lantern/signs)
			})
		end
	end
	
	-- ========================================
	-- BEDS (colored sheet variants using ColorPalette)
	-- ========================================
	local bedBlockTemplates = ReplicatedStorage:FindFirstChild("BlockTemplates")
	local bedTemplate = bedBlockTemplates and bedBlockTemplates:FindFirstChild("Bed")
	if bedTemplate then
		-- Custom sheet colors: palette colors tuned for SA.Color multiplier on white texture
		-- White uses (170,170,170) to avoid blowout on the bright texture
		local bedSheetColors = {}
		for _, colorName in ipairs(ColorPalette.ColorOrder) do
			local color = ColorPalette.Colors[colorName]
			if colorName == "White" then
				color = Color3.fromRGB(170, 170, 170)
			end
			table.insert(bedSheetColors, { name = colorName, color = color })
		end
		
		for _, colorData in ipairs(bedSheetColors) do
			local id = colorData.name .. "Bed"
			local displayName = colorData.name:gsub("(%l)(%u)", "%1 %2") .. " Bed"
			
			BedBlocks[id] = true
			
			table.insert(presets, {
				Id = id,
				Name = displayName,
				Category = "Decoration",
				Shape = "Block",
				Material = Enum.Material.Fabric,
				MaterialVariant = "",
				DefaultColor = colorData.color,
				UseBlockModel = false,
				BlockModelFolder = "BlockTemplates",
				BlockModelName = "Bed",
				IsBed = true,
				ApplyColor = false, -- Don't apply to BaseParts; handled via SurfaceAppearance
				CanRotate = true,
				SortPriority = 310, -- After wool in Decoration tab
			})
		end
	else
		warn("[BlockPresets] Bed template not found in BlockTemplates!")
	end
	
	-- ========================================
	-- DECORATIONS (flowers, grass -> Decoration category)
	-- ========================================
	if decorationsFolder then
		local decoNames = {}
		for _, deco in ipairs(decorationsFolder:GetChildren()) do
			-- Skip the Glass folder (handled separately)
			if deco.Name ~= "Glass" then
				table.insert(decoNames, deco.Name)
			end
		end
		table.sort(decoNames)
		
		for _, decoName in ipairs(decoNames) do
			local decoModel = decorationsFolder:FindFirstChild(decoName)
			if not decoModel then continue end
			
			-- Skip models that are handled manually
			if SkipAutoPreset[decoName] then continue end
			
			local color, material = extractBlockProperties(decoModel)
			local displayName = formatName(decoName)
			
			-- Saplings go in Decoration category with other plants
			local isSapling = SaplingBlocks[decoName] ~= nil
			local category = "Decoration"
			
			table.insert(presets, {
				Id = decoName,
				Name = displayName,
				Category = category,
				Shape = "Decoration",
				Material = material,
				DefaultColor = color,
				UseBlockModel = false, -- Use Decorations folder instead
				IsDecoration = true, -- Flag for special placement
				DecorationName = decoName,
				IsSaplingItem = isSapling, -- Flag for saplings
				TreeType = isSapling and SaplingBlocks[decoName] or nil, -- Tree type for saplings
			})
		end
	else
		warn("[BlockPresets] Decorations folder not found!")
	end
	
	-- ========================================
	-- TOOLS -> Items category
	-- ========================================
	local toolsFolder = ReplicatedStorage:FindFirstChild("Tools")
	if toolsFolder then
		for _, tool in ipairs(toolsFolder:GetChildren()) do
			local toolName = tool.Name
			local displayName = formatName(toolName)
			local color, material = extractBlockProperties(tool)
			
			-- Determine tool type based on name
			local isWiringTool = string.find(string.lower(toolName), "wir") ~= nil
			
			table.insert(presets, {
				Id = toolName,
				Name = displayName,
				Category = "Items", -- All tools go in Items
				Shape = "Block",
				Material = material,
				DefaultColor = color,
				UseBlockModel = true,
				BlockModelName = toolName,
				BlockModelFolder = "Tools", -- Special folder for tools
				IsTool = true,
				IsWiringTool = isWiringTool,
			})
		end
	else
		warn("[BlockPresets] Tools folder not found!")
	end
	
	-- ========================================
	-- WATER BUCKETS -> Items category
	-- ========================================
	
	-- Water Bucket: places a water source block
	table.insert(presets, {
		Id = "WaterBucket",
		Name = "Water Bucket",
		Category = "Items",
		Shape = "Block",
		Material = Enum.Material.Metal,
		DefaultColor = Color3.fromRGB(60, 120, 220),
		UseBlockModel = false,
		IsTool = true,
		IsWaterBucket = true,
		SortPriority = 50,
		HideFromInventory = true, -- Hidden until water system is fully polished
	})
	
	-- Empty Bucket: picks up a water source block
	table.insert(presets, {
		Id = "EmptyBucket",
		Name = "Empty Bucket",
		Category = "Items",
		Shape = "Block",
		Material = Enum.Material.Metal,
		DefaultColor = Color3.fromRGB(180, 180, 180),
		UseBlockModel = false,
		IsTool = true,
		IsEmptyBucket = true,
		SortPriority = 51,
		HideFromInventory = true, -- Hidden until water system is fully polished
	})
	
	-- ========================================
	-- WIRING (Buttons, Pressure Plates, Lamps)
	-- ========================================
	local blockTemplates = ReplicatedStorage:FindFirstChild("BlockTemplates")
	local buttonTemplate = blockTemplates and blockTemplates:FindFirstChild("Button")
	local pressurePlateTemplate = blockTemplates and blockTemplates:FindFirstChild("PressurePlate")
	
	-- Wood types to create variants for (extract from planks in Blocks folder)
	local woodTypes = {}
	if blocksFolder then
		for _, block in ipairs(blocksFolder:GetChildren()) do
			local name = block.Name
			-- Check for planks to determine wood types
			if string.find(name, "Planks") then
				local woodType = string.gsub(name, "Planks", "")
				table.insert(woodTypes, {
					name = woodType,
					color = extractBlockProperties(block),
					material = Enum.Material.Wood,
				})
			end
		end
	end
	
	-- Add stone type
	table.insert(woodTypes, {
		name = "Stone",
		color = Color3.fromRGB(128, 128, 128),
		material = Enum.Material.Concrete,
	})
	
	-- Create button variants for each wood type
	if buttonTemplate then
		for _, woodData in ipairs(woodTypes) do
			local id = woodData.name .. "Button"
			local displayName = formatName(woodData.name) .. " Button"
			
			table.insert(presets, {
				Id = id,
				Name = displayName,
				Category = "Wiring", -- Buttons go in Wiring
				Shape = "Block",
				Material = woodData.material,
				DefaultColor = woodData.color,
				UseBlockModel = true,
				BlockModelName = "Button",
				BlockModelFolder = "BlockTemplates",
				IsController = true,
				ApplyColor = true, -- Apply wood color to template
			})
		end
	else
		warn("[BlockPresets] Button template not found in BlockTemplates!")
	end
	
	-- Create pressure plate variants for each wood type
	if pressurePlateTemplate then
		for _, woodData in ipairs(woodTypes) do
			local id = woodData.name .. "PressurePlate"
			local displayName = formatName(woodData.name) .. " Pressure Plate"
			
			table.insert(presets, {
				Id = id,
				Name = displayName,
				Category = "Wiring", -- Pressure plates go in Wiring
				Shape = "Block",
				Material = woodData.material,
				DefaultColor = woodData.color,
				UseBlockModel = true,
				BlockModelName = "PressurePlate",
				BlockModelFolder = "BlockTemplates",
				IsController = true,
				ApplyColor = true,
			})
		end
	else
		warn("[BlockPresets] PressurePlate template not found in BlockTemplates!")
	end
	
	-- Lamp (controllable light)
	table.insert(presets, {
		Id = "Lamp",
		Name = "Lamp",
		Category = "Wiring",
		Shape = "Block",
		Material = Enum.Material.Neon,
		DefaultColor = Color3.fromRGB(200, 180, 100),
		UseBlockModel = false,
		IsControllable = true,
	})
	
	-- ========================================
	-- FENCES -> Building category
	-- ========================================
	
	-- Dynamically create fences for all wood types (from planks) plus stone types
	local fenceBaseBlocks = {}
	
	-- Add wood fences from all plank types
	if blocksFolder then
		for _, block in ipairs(blocksFolder:GetChildren()) do
			local name = block.Name
			if string.find(name, "Planks") then
				local woodType = string.gsub(name, "Planks", "")
				table.insert(fenceBaseBlocks, {
					name = woodType,
					baseBlock = name,
				})
			end
		end
	end
	
	-- Add stone fence types
	table.insert(fenceBaseBlocks, { name = "Stone", baseBlock = "Stone" })
	table.insert(fenceBaseBlocks, { name = "StoneBrick", baseBlock = "StoneBrick" })
	
	-- Sort alphabetically for consistent ordering
	table.sort(fenceBaseBlocks, function(a, b) return a.name < b.name end)
	
	-- Create fence presets for each type, extracting appearance from base block
	for _, fenceData in ipairs(fenceBaseBlocks) do
		local id = fenceData.name .. "Fence"
		local displayName = formatName(fenceData.name) .. " Fence"
		
		-- Extract appearance from base block
		local color = Color3.fromRGB(128, 128, 128)
		local material = Enum.Material.Wood
		local materialVariant = ""
		
		if blocksFolder then
			local baseBlockModel = blocksFolder:FindFirstChild(fenceData.baseBlock)
			if baseBlockModel then
				color, material, materialVariant = extractBlockProperties(baseBlockModel)
			end
		end
		
		-- Determine category (stone fences go to Nature)
		local fenceCategory = NatureBlocks[id] and "Nature" or "Building"
		
		-- Add to FenceBlocks lookup table
		FenceBlocks[id] = true
		
		table.insert(presets, {
			Id = id,
			Name = displayName,
			Category = fenceCategory,
			Shape = "Block",
			Material = material,
			MaterialVariant = materialVariant,
			DefaultColor = color,
			UseBlockModel = false,
			BlockModelFolder = "BlockTemplates", -- Look in BlockTemplates for preview
			BlockModelName = "FenceMiddle", -- Show middle piece as preview icon
			IsFence = true,
			ApplyColor = true,
			BaseBlock = fenceData.baseBlock, -- Reference to base block
		})
	end
	
	-- ========================================
	-- GLASS -> Building category
	-- ========================================
	
	-- Glass pane (auto-connecting)
	if not SHOW_GLASS then
		-- Skip glass for now
	elseif true then
	local glassFolder = ReplicatedStorage:FindFirstChild("Decorations")
	if glassFolder then
		local glassSubFolder = glassFolder:FindFirstChild("Glass")
		if glassSubFolder then
			-- Use Glass_0 (all edges) as the preview icon
			local previewModel = glassSubFolder:FindFirstChild("Glass_0")
			local color = Color3.fromRGB(200, 220, 255) -- Default light blue tint
			local material = Enum.Material.Glass
			
			if previewModel then
				color, material = extractBlockProperties(previewModel)
			end
			
			table.insert(presets, {
				Id = "Glass",
				Name = "Glass Pane",
				Category = "Decoration",
				Shape = "Block",
				Material = material,
				DefaultColor = color,
				UseBlockModel = true,
				BlockModelFolder = "Decorations/Glass", -- Look in Decorations/Glass subfolder
				BlockModelName = "Glass_0", -- Show all-edges piece as preview icon
				IsGlass = true,
				ApplyColor = false, -- Keep original glass appearance
				SortPriority = 152, -- Group with glass (after glass blocks)
			})
			
			-- Tinted glass variants (blocks + panes) using concrete colors
			local tintConcreteFolder = ReplicatedStorage:FindFirstChild("Concrete")
			if tintConcreteFolder then
				local tintNames = {}
				for _, concrete in ipairs(tintConcreteFolder:GetChildren()) do
					table.insert(tintNames, concrete.Name)
				end
				table.sort(tintNames)
				
				-- Saturate colors for glass: concrete pastels wash out on transparent material
				local function saturateForGlass(color)
					local r, g, b = color.R * 255, color.G * 255, color.B * 255
					local factor = 0.65 -- Darken to make tints visible through glass
					return Color3.fromRGB(
						math.round(r * factor),
						math.round(g * factor),
						math.round(b * factor)
					)
				end
				
				for _, concreteName in ipairs(tintNames) do
					if concreteName == "WhiteConcrete" then continue end -- White glass = regular glass
					local concreteModel = tintConcreteFolder:FindFirstChild(concreteName)
					if not concreteModel then continue end
					
					local tintColor = saturateForGlass(extractBlockProperties(concreteModel))
					local colorName = concreteName:gsub("Concrete", "")
					local displayColor = colorName:gsub("(%l)(%u)", "%1 %2")
					
					-- Tinted glass block (full block)
					local glassBlockId = colorName .. "GlassBlock"
					table.insert(presets, {
						Id = glassBlockId,
						Name = displayColor .. " Glass",
						Category = "Decoration",
						Shape = "Block",
						Material = Enum.Material.Glass,
						DefaultColor = tintColor,
						UseBlockModel = true,
						BlockModelName = "GlassBlock",
						ApplyColor = true,
						BaseBlock = glassBlockId,
						SortPriority = 151, -- After plain glass block, before panes
					})
					
					-- Tinted glass pane (auto-connecting)
					local glassPaneId = colorName .. "Glass"
					GlassBlocks[glassPaneId] = true -- Register for auto-connect
					table.insert(presets, {
						Id = glassPaneId,
						Name = displayColor .. " Glass Pane",
						Category = "Decoration",
						Shape = "Block",
						Material = Enum.Material.Glass,
						DefaultColor = tintColor,
						UseBlockModel = true,
						BlockModelFolder = "Decorations/Glass",
						BlockModelName = "Glass_0",
						IsGlass = true,
						ApplyColor = true,
						BaseBlock = glassPaneId,
						SortPriority = 153, -- After plain glass pane
					})
				end
			end
		else
			warn("[BlockPresets] Glass subfolder not found in Decorations!")
		end
	else
		warn("[BlockPresets] Decorations folder not found for Glass!")
	end
	end -- end SHOW_GLASS check
	
	-- ========================================
	-- LADDERS -> Building category
	-- ========================================
	
	-- Dynamically create ladders for all wood types (from planks)
	local ladderTemplate = blockTemplates and blockTemplates:FindFirstChild("Ladder")
	
	if ladderTemplate then
		-- Get wood types for ladder variants (exclude stone - ladders are wood only)
		local ladderWoodTypes = {}
		if blocksFolder then
			for _, block in ipairs(blocksFolder:GetChildren()) do
				local name = block.Name
				if string.find(name, "Planks") then
					local woodType = string.gsub(name, "Planks", "")
					table.insert(ladderWoodTypes, {
						name = woodType,
						baseBlock = name,
					})
				end
			end
		end
		
		-- Sort alphabetically for consistent ordering
		table.sort(ladderWoodTypes, function(a, b) return a.name < b.name end)
		
		-- Create ladder presets for each wood type
		for _, woodData in ipairs(ladderWoodTypes) do
			local id = woodData.name .. "Ladder"
			local displayName = formatName(woodData.name) .. " Ladder"
			
			-- Extract appearance from base block (planks)
			local color = Color3.fromRGB(128, 128, 128)
			local material = Enum.Material.Wood
			local materialVariant = ""
			
			if blocksFolder then
				local baseBlockModel = blocksFolder:FindFirstChild(woodData.baseBlock)
				if baseBlockModel then
					color, material, materialVariant = extractBlockProperties(baseBlockModel)
				end
			end
			
			-- Add to LadderBlocks lookup table
			LadderBlocks[id] = true
			
			table.insert(presets, {
				Id = id,
				Name = displayName,
				Category = "Building", -- Ladders go in Building
				Shape = "Block",
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = false, -- Must be false so SaveManager applies color on load
				BlockModelFolder = "BlockTemplates", -- Look in BlockTemplates for template
				BlockModelName = "Ladder", -- Use the Ladder template
				IsLadder = true,
				ApplyColor = true, -- Apply wood color to template
				BaseBlock = woodData.baseBlock, -- Reference to base block
			})
		end
		
		-- print("[BlockPresets] Added " .. #ladderWoodTypes .. " ladder variants")
	else
		warn("[BlockPresets] Ladder template not found in BlockTemplates!")
	end
	
	-- ========================================
	-- CRATES -> Building category
	-- ========================================
	
	-- Dynamically create crates for all wood types (from planks)
	local crateTemplate = blockTemplates and blockTemplates:FindFirstChild("CrateBlock")
	
	if crateTemplate then
		-- Get wood types for crate variants
		local crateWoodTypes = {}
		if blocksFolder then
			for _, block in ipairs(blocksFolder:GetChildren()) do
				local name = block.Name
				if string.find(name, "Planks") then
					local woodType = string.gsub(name, "Planks", "")
					table.insert(crateWoodTypes, {
						name = woodType,
						baseBlock = name,
					})
				end
			end
		end
		
		-- Sort alphabetically for consistent ordering
		table.sort(crateWoodTypes, function(a, b) return a.name < b.name end)
		
		-- Create crate presets for each wood type
		for _, woodData in ipairs(crateWoodTypes) do
			local id = woodData.name .. "Crate"
			local displayName = formatName(woodData.name) .. " Crate"
			
			-- Extract appearance from base block (planks)
			local color = Color3.fromRGB(128, 128, 128)
			local material = Enum.Material.Wood
			local materialVariant = ""
			
			if blocksFolder then
				local baseBlockModel = blocksFolder:FindFirstChild(woodData.baseBlock)
				if baseBlockModel then
					color, material, materialVariant = extractBlockProperties(baseBlockModel)
				end
			end
			
			-- Add to CrateBlocks lookup table
			CrateBlocks[id] = true
			
			table.insert(presets, {
				Id = id,
				Name = displayName,
				Category = "Building",
				Shape = "Block",
				Material = material,
				MaterialVariant = "PixelCrate", -- Keep the crate material variant
				DefaultColor = color,
				UseBlockModel = false, -- So SaveManager applies color on load
				BlockModelFolder = "BlockTemplates",
				BlockModelName = "CrateBlock",
				IsCrate = true,
				ApplyColor = true, -- Apply wood color to template
				BaseBlock = woodData.baseBlock,
			})
		end
		
		-- print("[BlockPresets] Added " .. #crateWoodTypes .. " crate variants")
	else
		warn("[BlockPresets] CrateBlock template not found in BlockTemplates!")
	end
	
	-- ========================================
	-- CHESTS -> Decoration category
	-- ========================================
	
	local chestTemplate = blockTemplates and blockTemplates:FindFirstChild("SingleChest")
	
	if chestTemplate then
		-- Get wood types for chest variants
		local chestWoodTypes = {}
		if blocksFolder then
			for _, block in ipairs(blocksFolder:GetChildren()) do
				local name = block.Name
				if string.find(name, "Planks") then
					local woodType = string.gsub(name, "Planks", "")
					table.insert(chestWoodTypes, {
						name = woodType,
						baseBlock = name,
					})
				end
			end
		end
		
		-- Sort alphabetically for consistent ordering
		table.sort(chestWoodTypes, function(a, b) return a.name < b.name end)
		
		-- Create chest presets for each wood type
		for _, woodData in ipairs(chestWoodTypes) do
			local id = woodData.name .. "Chest"
			local displayName = formatName(woodData.name) .. " Chest"
			
			-- Extract appearance from base block (planks)
			local color = Color3.fromRGB(128, 128, 128)
			local material = Enum.Material.Wood
			local materialVariant = ""
			
			if blocksFolder then
				local baseBlockModel = blocksFolder:FindFirstChild(woodData.baseBlock)
				if baseBlockModel then
					color, material, materialVariant = extractBlockProperties(baseBlockModel)
				end
			end
			
			-- Add to ChestBlocks lookup table
			ChestBlocks[id] = true
			
			table.insert(presets, {
				Id = id,
				Name = displayName,
				Category = "Decoration",
				Shape = "Block",
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = false,
				BlockModelFolder = "BlockTemplates",
				BlockModelName = "SingleChest",
				IsChest = true,
				ApplyColor = true,
				BaseBlock = woodData.baseBlock,
				CanRotate = true,
				SortPriority = 205, -- After Lantern, before Signs
			})
		end
		
		-- print("[BlockPresets] Added " .. #chestWoodTypes .. " chest variants")
	else
		warn("[BlockPresets] SingleChest template not found in BlockTemplates!")
	end
	
	-- ========================================
	-- CRAFTING TABLES -> Decoration category
	-- ========================================
	
	local craftingTableTemplate = blockTemplates and blockTemplates:FindFirstChild("CraftingTable")
	
	if craftingTableTemplate then
		-- Get wood types for crafting table variants
		local ctWoodTypes = {}
		if blocksFolder then
			for _, block in ipairs(blocksFolder:GetChildren()) do
				local name = block.Name
				if string.find(name, "Planks") then
					local woodType = string.gsub(name, "Planks", "")
					table.insert(ctWoodTypes, {
						name = woodType,
						baseBlock = name,
					})
				end
			end
		end
		
		-- Sort alphabetically for consistent ordering
		table.sort(ctWoodTypes, function(a, b) return a.name < b.name end)
		
		-- Create crafting table presets for each wood type
		for _, woodData in ipairs(ctWoodTypes) do
			local id = woodData.name .. "CraftingTable"
			local displayName = formatName(woodData.name) .. " Crafting Table"
			
			-- Extract appearance from base block (planks)
			local color = Color3.fromRGB(128, 128, 128)
			local material = Enum.Material.Wood
			local materialVariant = ""
			
			if blocksFolder then
				local baseBlockModel = blocksFolder:FindFirstChild(woodData.baseBlock)
				if baseBlockModel then
					color, material, materialVariant = extractBlockProperties(baseBlockModel)
				end
			end
			
			-- Add to CraftingTableBlocks lookup table
			CraftingTableBlocks[id] = true
			
			-- Get the leather tint for this wood type (fallback to warm brown)
			local leatherTint = CraftingTableLeatherTints[woodData.name] or Color3.fromRGB(160, 110, 60)
			
			table.insert(presets, {
				Id = id,
				Name = displayName,
				Category = "Decoration",
				Shape = "Block",
				Material = material,
				MaterialVariant = materialVariant, -- Use the wood's own plank texture
				DefaultColor = color,
				UseBlockModel = false,
				BlockModelFolder = "BlockTemplates",
				BlockModelName = "CraftingTable",
				IsCraftingTable = true,
				ApplyColor = true, -- Apply wood color to Block part
				BaseBlock = woodData.baseBlock,
				LeatherTint = leatherTint, -- Custom leather overlay color
				CanRotate = true,
				SortPriority = 207, -- After chests
			})
		end
		
		-- print("[BlockPresets] Added " .. #ctWoodTypes .. " crafting table variants")
	else
		warn("[BlockPresets] CraftingTable template not found in BlockTemplates!")
	end
	
	-- ========================================
	-- TORCHES & CAMPFIRES -> Decoration category
	-- ========================================
	
	-- Torch (special placement - straight on top, angled on sides)
	-- Look in Decorations folder for torch models
	if decorationsFolder then
		-- Check for torch models
		local torchStraight = decorationsFolder:FindFirstChild("TorchStraight")
		local torchAngled = decorationsFolder:FindFirstChild("TorchAngled")
		
		if torchStraight then
			local color, material = extractBlockProperties(torchStraight)
			
			table.insert(presets, {
				Id = "Torch",
				Name = "Torch",
				Category = "Decoration",
				Shape = "Block",
				Material = material,
				DefaultColor = color,
				UseBlockModel = true,
				BlockModelName = "TorchStraight", -- Default preview model
				BlockModelFolder = "Decorations",
				IsTorch = true,
				ApplyColor = false, -- Keep original torch appearance
				SortPriority = 200, -- After vegetation
			})
			
			-- print("[BlockPresets] Added Torch preset")
		else
			warn("[BlockPresets] TorchStraight model not found in Decorations folder!")
		end
		
		-- Campfire (placed on top of blocks only, emits smoke)
		local campfireModel = decorationsFolder:FindFirstChild("Campfire")
		if campfireModel then
			local campfireColor, campfireMaterial = extractBlockProperties(campfireModel)
			
			table.insert(presets, {
				Id = "Campfire",
				Name = "Campfire",
				Category = "Decoration",
				Shape = "Block",
				Material = campfireMaterial,
				DefaultColor = campfireColor,
				UseBlockModel = true,
				BlockModelName = "Campfire",
				BlockModelFolder = "Decorations",
				IsCampfire = true,
				ApplyColor = false, -- Keep original campfire appearance
				SortPriority = 201, -- After Torch
			})
			
			-- print("[BlockPresets] Added Campfire preset")
		else
			warn("[BlockPresets] Campfire model not found in Decorations folder!")
		end
		
		-- Column Torch (campfire-style light on a column pedestal)
		local columnTorchModel = decorationsFolder:FindFirstChild("ColumnTorch")
		if columnTorchModel then
			local ctColor, ctMaterial = extractBlockProperties(columnTorchModel)
			
			table.insert(presets, {
				Id = "ColumnTorch",
				Name = "Column Torch",
				Category = "Building",
				Shape = "Block",
				Material = ctMaterial,
				DefaultColor = ctColor,
				UseBlockModel = true,
				BlockModelName = "ColumnTorch",
				BlockModelFolder = "Decorations",
				IsCampfire = true,
				ApplyColor = false,
				HideFromInventory = true, -- Locked until Roman Architecture mod is purchased
			})
		else
			warn("[BlockPresets] ColumnTorch model not found in Decorations folder!")
		end
		
		-- Lantern (placed on top or bottom of blocks only)
		local lanternModel = decorationsFolder:FindFirstChild("Lantern")
		if lanternModel then
			local lanternColor, lanternMaterial = extractBlockProperties(lanternModel)
			
			table.insert(presets, {
				Id = "Lantern",
				Name = "Lantern",
				Category = "Decoration",
				Shape = "Block",
				Material = lanternMaterial,
				DefaultColor = lanternColor,
				UseBlockModel = true,
				BlockModelName = "Lantern",
				BlockModelFolder = "Decorations",
				IsLantern = true,
				ApplyColor = false, -- Keep original lantern appearance
				SortPriority = 202, -- After Campfire
			})
			
			-- print("[BlockPresets] Added Lantern preset")
		else
			warn("[BlockPresets] Lantern model not found in Decorations folder!")
		end
	end
	
	-- Vine (placed on side faces of blocks, spreads downward naturally)
	if decorationsFolder then
		local vineModel = decorationsFolder:FindFirstChild("Vine")
		if vineModel then
			local vineColor, vineMaterial = extractBlockProperties(vineModel)
			
			table.insert(presets, {
				Id = "Vine",
				Name = "Vine",
				Category = "Decoration",
				Shape = "Block",
				Material = vineMaterial,
				DefaultColor = vineColor,
				UseBlockModel = true,
				BlockModelName = "Vine",
				BlockModelFolder = "Decorations",
				IsVine = true,
				ApplyColor = false, -- Keep original vine appearance
				SortPriority = 203, -- After Lantern
			})
		else
			warn("[BlockPresets] Vine model not found in Decorations folder!")
		end
	end
	
	-- VineTrimmed / VineTrimmedEnd: hidden presets (created by Shears tool, not placeable directly).
	-- They have IsVine = true so they participate in save/load and climbing,
	-- and IsVineTrimmed = true so the spread system skips them.
	if decorationsFolder then
		local vineTrimmedModel = decorationsFolder:FindFirstChild("VineTrimmed")
		if vineTrimmedModel then
			local c, m = extractBlockProperties(vineTrimmedModel)
			table.insert(presets, {
				Id = "VineTrimmed",
				Name = "Vine (Trimmed)",
				Category = "Decoration",
				Shape = "Block",
				Material = m,
				DefaultColor = c,
				UseBlockModel = true,
				BlockModelName = "VineTrimmed",
				BlockModelFolder = "Decorations",
				IsVine = true,
				IsVineTrimmed = true,
				ApplyColor = false,
				HideFromInventory = true, -- Only obtainable via Shears
			})
		end
		
		local vineTrimmedEndModel = decorationsFolder:FindFirstChild("VineTrimmedEnd")
		if vineTrimmedEndModel then
			local c, m = extractBlockProperties(vineTrimmedEndModel)
			table.insert(presets, {
				Id = "VineTrimmedEnd",
				Name = "Vine End (Trimmed)",
				Category = "Decoration",
				Shape = "Block",
				Material = m,
				DefaultColor = c,
				UseBlockModel = true,
				BlockModelName = "VineTrimmedEnd",
				BlockModelFolder = "Decorations",
				IsVine = true,
				IsVineTrimmed = true,
				ApplyColor = false,
				HideFromInventory = true, -- Only obtainable via Shears
			})
		end
	end
	
	-- ========================================
	-- COLUMNS -> Building category
	-- ========================================
	if blocksFolder then
		local columnModel = blocksFolder:FindFirstChild("ColumnSingle")
		if columnModel then
			local colColor, colMaterial, colMaterialVariant = extractBlockProperties(columnModel)
			table.insert(presets, {
				Id = "Column",
				Name = "Column",
				Category = "Building",
				Shape = "Block",
				Material = colMaterial,
				MaterialVariant = colMaterialVariant,
				DefaultColor = colColor,
				UseBlockModel = true,
				BlockModelName = "ColumnSingle", -- Viewport/default model
				BlockModelFolder = "Blocks",
				IsColumn = true,
				ApplyColor = false, -- Keep original column appearance
				HideFromInventory = true, -- Locked until Roman Architecture mod is purchased
			})
		else
			warn("[BlockPresets] ColumnSingle model not found in Blocks folder!")
		end
	end
	
	-- ========================================
	-- ARCHITRAVES -> Building category
	-- ========================================
	local architravesFolder = ReplicatedStorage:FindFirstChild("Architraves")
	if architravesFolder then
		local singleModel = architravesFolder:FindFirstChild("ArchitraveSingle")
		if singleModel then
			local archColor, archMaterial, archMaterialVariant = extractBlockProperties(singleModel)
			table.insert(presets, {
				Id = "Architrave",
				Name = "Architrave",
				Category = "Building",
				Shape = "Block",
				Material = archMaterial,
				MaterialVariant = archMaterialVariant,
				DefaultColor = archColor,
				UseBlockModel = true,
				BlockModelName = "ArchitraveSingle",
				BlockModelFolder = "Architraves",
				IsArchitrave = true,
				ApplyColor = false,
				HideFromInventory = true, -- Locked until Roman Architecture mod is purchased
			})
		else
			warn("[BlockPresets] ArchitraveSingle model not found in Architraves folder!")
		end
	else
		warn("[BlockPresets] Architraves folder not found in ReplicatedStorage!")
	end
	
	-- ========================================
	-- ARCHES -> Building category
	-- Arch blocks with auto-corners (like stairs but curved)
	-- ========================================
	local blockTemplatesForArch = ReplicatedStorage:FindFirstChild("BlockTemplates")
	if blockTemplatesForArch then
		local archModel = blockTemplatesForArch:FindFirstChild("Arch")
		if archModel then
			local archColor, archMaterial, archMaterialVariant = extractBlockProperties(archModel)
			table.insert(presets, {
				Id = "Arch",
				Name = "Arch",
				Category = "Building",
				Shape = "Arch",
				Material = archMaterial,
				MaterialVariant = archMaterialVariant,
				DefaultColor = archColor,
				UseBlockModel = true,
				BlockModelName = "Arch",
				BlockModelFolder = "BlockTemplates",
				IsArch = true,
				ApplyColor = false,
				HideFromInventory = true, -- Players use frame variant (ArchFrame)
			})
		else
			warn("[BlockPresets] Arch model not found in BlockTemplates folder!")
		end
		
		-- ArchLarge (solid)
		local archLargeModel = blockTemplatesForArch:FindFirstChild("ArchLarge")
		if archLargeModel then
			local alColor, alMaterial, alMaterialVariant = extractBlockProperties(archLargeModel)
			table.insert(presets, {
				Id = "ArchLarge",
				Name = "Arch Large",
				Category = "Building",
				Shape = "ArchLarge",
				Material = alMaterial,
				MaterialVariant = alMaterialVariant,
				DefaultColor = alColor,
				UseBlockModel = true,
				BlockModelName = "ArchLarge",
				BlockModelFolder = "BlockTemplates",
				IsArch = true,
				ApplyColor = false,
				HideFromInventory = true, -- Players use frame variant (ArchLargeFrame)
			})
		else
			warn("[BlockPresets] ArchLarge model not found in BlockTemplates folder!")
		end
	end
	
	-- ========================================
	-- SIGNS -> Decoration category
	-- ========================================
	
	-- Dynamically create signs for all wood types (from planks)
	local signStandingTemplate = blockTemplates and blockTemplates:FindFirstChild("SignStanding")
	local wallSignTemplate = blockTemplates and blockTemplates:FindFirstChild("Sign")
	
	if signStandingTemplate and wallSignTemplate then
		-- Get wood types for sign variants (from planks)
		local signWoodTypes = {}
		if blocksFolder then
			for _, block in ipairs(blocksFolder:GetChildren()) do
				local name = block.Name
				if string.find(name, "Planks") then
					local woodType = string.gsub(name, "Planks", "")
					table.insert(signWoodTypes, {
						name = woodType,
						baseBlock = name,
					})
				end
			end
		end
		
		-- Sort alphabetically for consistent ordering
		table.sort(signWoodTypes, function(a, b) return a.name < b.name end)
		
		-- Create sign presets for each wood type
		for _, woodData in ipairs(signWoodTypes) do
			-- Extract appearance from base block (planks)
			local color = Color3.fromRGB(128, 128, 128)
			local material = Enum.Material.Wood
			local materialVariant = ""
			
			if blocksFolder then
				local baseBlockModel = blocksFolder:FindFirstChild(woodData.baseBlock)
				if baseBlockModel then
					color, material, materialVariant = extractBlockProperties(baseBlockModel)
				end
			end
			
			-- Standing Sign (top-only, 16-direction rotation)
			local standingId = woodData.name .. "SignStanding"
			local standingDisplayName = formatName(woodData.name) .. " Sign"
			
			-- Add to SignStandingBlocks lookup table
			SignStandingBlocks[standingId] = true
			
			table.insert(presets, {
				Id = standingId,
				Name = standingDisplayName,
				Category = "Decoration",
				Shape = "Block",
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = true,
				BlockModelFolder = "BlockTemplates",
				BlockModelName = "SignStanding",
				IsSignStanding = true,
				ApplyColor = true, -- Apply wood color to Sign part only
				BaseBlock = woodData.baseBlock,
				SortPriority = 210, -- After Torch/Campfire/Lantern
			})
			
			-- Wall Sign (side-only placement) - hidden from inventory
			-- Still needed for save/load, just not shown in UI
			local wallId = woodData.name .. "Sign"
			local wallDisplayName = formatName(woodData.name) .. " Wall Sign"
			
			-- Add to WallSignBlocks lookup table (still needed for save/load)
			WallSignBlocks[wallId] = true
			
			table.insert(presets, {
				Id = wallId,
				Name = wallDisplayName,
				Category = "Decoration",
				Shape = "Block",
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = true,
				BlockModelFolder = "BlockTemplates",
				BlockModelName = "Sign",
				IsWallSign = true,
				ApplyColor = true, -- Apply wood color to entire sign
				BaseBlock = woodData.baseBlock,
				HideFromInventory = true, -- Don't show in inventory UI
			})
		end
		
		-- print("[BlockPresets] Added " .. #signWoodTypes .. " sign variants (standing + wall)")
	else
		if not signStandingTemplate then
			warn("[BlockPresets] SignStanding template not found in BlockTemplates!")
		end
		if not wallSignTemplate then
			warn("[BlockPresets] Sign template not found in BlockTemplates!")
		end
	end
	
	-- ========================================
	-- GLOWSTONE (colored light-emitting blocks) -> Lights category
	-- ========================================
	local glowstoneTemplate = blockTemplates and blockTemplates:FindFirstChild("Glowstone")
	
	if glowstoneTemplate then
		-- Get all light-suitable colors from the palette (excludes grey/darkgrey/black)
		local lightColors = ColorPalette.getLightColors()
		
		for _, colorData in ipairs(lightColors) do
			local colorName = colorData.name
			local color = colorData.color
			
			local id = colorName .. "Glowstone"
			-- Format display name: "LightBlue" -> "Light Blue"
			local displayColorName = colorName:gsub("(%l)(%u)", "%1 %2")
			local displayName = displayColorName .. " Glowstone"
			
			-- Add to lookup table
			GlowstoneBlocks[id] = true
			
			table.insert(presets, {
				Id = id,
				Name = displayName,
				Category = "Lights",
				Shape = "Block",
				Material = nil, -- Keep template's original material
				DefaultColor = color,
				UseBlockModel = true,
				BlockModelName = "Glowstone",
				BlockModelFolder = "BlockTemplates",
				IsGlowstone = true,
				ApplyColor = true, -- Apply palette color to block and PointLight
				GlowstoneColor = colorName, -- Store the color name for reference
			})
		end
		
		-- print("[BlockPresets] Added " .. #lightColors .. " Glowstone color variants")
	else
		warn("[BlockPresets] Glowstone template not found in BlockTemplates!")
	end
	
	-- ========================================
	-- FRAME BLOCKS -> Frames category
	-- Wireframe blocks that can be "filled" with any block's color/material
	-- ========================================
	local frameBlocksFolder = ReplicatedStorage:FindFirstChild("FrameBlocks")
	
	if frameBlocksFolder then
		-- Frame block shape mapping
		local frameShapeMap = {
			["FrameBlock"] = "Block",
			["FrameSlab"] = "Slab",
			["FrameStairs"] = "Stair",
			["FrameStairsCornerInner"] = "Stair",
			["FrameStairsCornerOuter"] = "Stair",
			["FrameDoor"] = "Block", -- Doors use Block shape but have IsDoor flag
			["WallpaperFrame"] = "Block", -- Wallpaper frames snap to block faces
			["SignStandingFrame"] = "Block", -- Standing sign frame (top placement)
			["SignFrame"] = "Block", -- Wall sign frame (side placement)
			["CarpetFrame"] = "Block", -- Thin carpet, top-only placement
			["ArchFrame"] = "Arch",
			["ArchInnerFrame"] = "Arch",
			["ArchOuterFrame"] = "Arch",
			["ArchLargeFrame"] = "ArchLarge",
			["ArchLargeInnerFrame"] = "ArchLarge",
			["ArchLargeOuterFrame"] = "ArchLarge",
		}
		
		-- Display names
		local frameDisplayNames = {
			["FrameBlock"] = "Frame Block",
			["FrameSlab"] = "Frame Slab",
			["FrameStairs"] = "Frame Stairs",
			["FrameStairsCornerInner"] = "Frame Stair Inner Corner",
			["FrameStairsCornerOuter"] = "Frame Stair Outer Corner",
			["FrameDoor"] = "Frame Door",
			["WallpaperFrame"] = "Wallpaper Frame",
			["SignStandingFrame"] = "Frame Sign",
			["SignFrame"] = "Frame Wall Sign",
			["CarpetFrame"] = "Frame Carpet",
			["ArchFrame"] = "Arch Frame",
			["ArchInnerFrame"] = "Arch Frame Inner Corner",
			["ArchOuterFrame"] = "Arch Frame Outer Corner",
			["ArchLargeFrame"] = "Arch Large Frame",
			["ArchLargeInnerFrame"] = "Arch Large Frame Inner Corner",
			["ArchLargeOuterFrame"] = "Arch Large Frame Outer Corner",
		}
		
		-- Corner pieces are auto-detected, not shown in inventory
		-- Fence frame variants are internal templates used by auto-connection system
		local frameCornerPieces = {
			["FrameStairsCornerInner"] = true,
			["FrameStairsCornerOuter"] = true,
			["FencePostFrame"] = true,
			["FenceEndFrame"] = true,
			["FenceMiddleFrame"] = true,
			["FenceCornerFrame"] = true,
			["FenceMiddleCornerFrame"] = true,
			["FenceMiddleFourFrame"] = true,
			["ArchInnerFrame"] = true,
			["ArchOuterFrame"] = true,
			["ArchLargeInnerFrame"] = true,
			["ArchLargeOuterFrame"] = true,
		}
		
		local frameNames = {}
		for _, frame in ipairs(frameBlocksFolder:GetChildren()) do
			table.insert(frameNames, frame.Name)
		end
		table.sort(frameNames)
		
		for _, frameName in ipairs(frameNames) do
			local frameModel = frameBlocksFolder:FindFirstChild(frameName)
			if not frameModel then continue end
			
			local color, material, materialVariant = extractBlockProperties(frameModel)
			local shape = frameShapeMap[frameName] or "Block"
			local displayName = frameDisplayNames[frameName] or formatName(frameName)
			local isFrameDoor = (frameName == "FrameDoor")
			local isWallpaper = (frameName == "WallpaperFrame")
			local isSignStandingFrame = (frameName == "SignStandingFrame")
			local isSignFrame = (frameName == "SignFrame")
			local isCarpet = (frameName == "CarpetFrame")
			local isArchFrame = (frameName == "ArchFrame" or frameName == "ArchLargeFrame")
			
			-- Add to FrameBlocks lookup (all pieces including corners)
			FrameBlocks[frameName] = true
			
			-- Also register as door if it's FrameDoor
			if isFrameDoor then
				DoorBlocks[frameName] = true
			end
			
			-- Register sign frames in sign lookup tables (for placement logic)
			if isSignStandingFrame then
				SignStandingBlocks[frameName] = true
			end
			if isSignFrame then
				WallSignBlocks[frameName] = true
			end
			
			-- Skip corner pieces from inventory (auto-detected like regular stairs)
			if frameCornerPieces[frameName] then continue end
			
			table.insert(presets, {
				Id = frameName,
				Name = displayName,
				Category = "Frames",
				Shape = shape,
				Material = material,
				MaterialVariant = materialVariant,
				DefaultColor = color,
				UseBlockModel = true,
				BlockModelName = frameName,
				BlockModelFolder = "FrameBlocks",
				IsFrameBlock = true,
				IsDoor = isFrameDoor or nil,
				IsWallpaperFrame = isWallpaper or nil,
				IsSignStanding = isSignStandingFrame or nil,
				IsWallSign = isSignFrame or nil,
				IsCarpet = isCarpet or nil,
				IsArch = isArchFrame or nil,
				BaseBlock = frameName,
				ApplyColor = false, -- Keep original frame appearance (fill changes it)
				HideFromInventory = (isSignFrame or frameName == "ArchLargeFrame") or nil, -- Wall sign frame is auto-swapped; ArchLargeFrame hidden from catalog
			})
		end
		
		-- FrameFence: wireframe fence that auto-connects like regular fences
		-- Uses FencePostFrame/FenceEndFrame/etc from FrameBlocks
		FenceBlocks["FrameFence"] = true
		FrameBlocks["FrameFence"] = true
		
		-- Get color/material from FenceMiddleFrame for the preview
		local fencePreviewModel = frameBlocksFolder:FindFirstChild("FenceMiddleFrame")
		local fenceFrameColor = Color3.fromRGB(128, 128, 128)
		local fenceFrameMaterial = Enum.Material.Plastic
		local fenceFrameMaterialVariant = ""
		if fencePreviewModel then
			fenceFrameColor, fenceFrameMaterial, fenceFrameMaterialVariant = extractBlockProperties(fencePreviewModel)
		end
		
		table.insert(presets, {
			Id = "FrameFence",
			Name = "Frame Fence",
			Category = "Frames",
			Shape = "Block",
			Material = fenceFrameMaterial,
			MaterialVariant = fenceFrameMaterialVariant,
			DefaultColor = fenceFrameColor,
			UseBlockModel = true,
			BlockModelName = "FenceMiddleFrame",
			BlockModelFolder = "FrameBlocks",
			IsFrameBlock = true,
			IsFence = true,
			ApplyColor = false,
			BaseBlock = "FrameFence",
		})
		
		-- print("[BlockPresets] Added " .. #frameNames .. " Frame block presets")
	else
		warn("[BlockPresets] FrameBlocks folder not found in ReplicatedStorage!")
	end
	
	return presets
end

-- Generate presets at module load
local Presets = generatePresets()

-- Append auto-generated reward block presets (from ReplicatedStorage.RewardSets)
local rewardPresetsOk, RewardBlockPresets = pcall(require, ReplicatedStorage:WaitForChild("RewardBlockPresets"))
if rewardPresetsOk and RewardBlockPresets then
	local rewardPresets = RewardBlockPresets.Generate()
	for _, preset in ipairs(rewardPresets) do
		table.insert(Presets, preset)
	end
	if #rewardPresets > 0 then
		print(string.format("[BlockPresets] Added %d reward-block preset(s) from RewardSets folder", #rewardPresets))
	end
else
	warn("[BlockPresets] Could not load RewardBlockPresets module")
end

-- Categories in display order (Minecraft-style)
-- IconBlock: block ID to show in the viewport, IconFolder: where to find the icon model
local Categories = {
	{ Name = "Nature", IconBlock = "GrassBlock", IconFolder = "Blocks" },
	{ Name = "Building", IconBlock = "OakPlanks", IconFolder = "Blocks" },
	{ Name = "Decoration", IconBlock = "TorchStraight", IconFolder = "Decorations" }, -- Torch/Campfire in Decorations
	{ Name = "Colors", IconBlock = "BlueConcrete", IconFolder = "Concrete" },
	{ Name = "Lights", IconBlock = "Glowstone", IconFolder = "BlockTemplates" }, -- Only Glowstones now
	{ Name = "Frames", IconBlock = "FrameBlock", IconFolder = "FrameBlocks" },
	{ Name = "Wiring", IconBlock = "Piston", IconFolder = "Blocks" },
	{ Name = "Items", IconBlock = "WireTool", IconFolder = "Tools" },
}

-- Lookup functions
local function GetPreset(id)
	for _, preset in ipairs(Presets) do
		if preset.Id == id then
			return preset
		end
	end
	return nil
end

-- Shape sort order for Minecraft-style grouping (blocks first, then slabs, then stairs)
local ShapeSortOrder = {
	["Block"] = 1,
	["Decoration"] = 1, -- Decorations sort with blocks
	["Slab"] = 2,       -- Slabs second
	["Stair"] = 3,      -- Stairs third
	["StairInner"] = 3,
	["StairOuter"] = 3,
	["Arch"] = 4,        -- Arches after stairs
	["ArchInner"] = 4,
	["ArchOuter"] = 4,
	["ArchLarge"] = 5,   -- Large arches after arches
	["ArchLargeInner"] = 5,
	["ArchLargeOuter"] = 5,
}

local function GetPresetsByCategory(category)
	local result = {}
	for _, preset in ipairs(Presets) do
		if preset.Category == category and not preset.HideFromInventory then
			table.insert(result, preset)
		end
	end
	
	-- Sort by: 1) SortPriority, 2) shape type, 3) block sub-type, 4) alphabetically
	table.sort(result, function(a, b)
		-- Check sort priority first (lower = earlier, nil = default 100)
		local priorityA = a.SortPriority or 100
		local priorityB = b.SortPriority or 100
		
		if priorityA ~= priorityB then
			return priorityA < priorityB
		end
		
		-- Shape type sorting (blocks first, then slabs, then stairs)
		local orderA = ShapeSortOrder[a.Shape] or 1
		local orderB = ShapeSortOrder[b.Shape] or 1
		
		if orderA ~= orderB then
			return orderA < orderB
		end
		
		-- Sub-type sorting within blocks: regular blocks, then fences, then ladders, then doors
		local function getSubType(preset)
			if preset.IsFence then return 2
			elseif preset.IsLadder then return 3
			elseif preset.IsDoor then return 4
			else return 1 end
		end
		
		local subTypeA = getSubType(a)
		local subTypeB = getSubType(b)
		
		if subTypeA ~= subTypeB then
			return subTypeA < subTypeB
		end
		
		-- Within same type, sort alphabetically
		return a.Name < b.Name
	end)
	
	return result
end

local function GetShape(shapeName)
	return Shapes[shapeName]
end

local function GetAllPresets()
	return Presets
end

local function GetAllCategories()
	return Categories
end

local function GetAllColors()
	return Colors
end

local function IsDecoration(id)
	local preset = GetPreset(id)
	return preset and preset.IsDecoration == true
end

local function IsDoor(id)
	local preset = GetPreset(id)
	return preset and preset.IsDoor == true
end

local function IsFence(id)
	return FenceBlocks[id] == true
end

local function IsGlass(id)
	return GlassBlocks[id] == true
end

local function IsSapling(id)
	return SaplingBlocks[id] ~= nil
end

local function GetSaplingTreeType(id)
	return SaplingBlocks[id]
end

local function IsLadder(id)
	return LadderBlocks[id] == true
end

local function IsTorch(id)
	return TorchBlocks[id] == true
end

local function IsCampfire(id)
	return CampfireBlocks[id] == true
end

local function IsLantern(id)
	return LanternBlocks[id] == true
end

local function IsColumn(id)
	return ColumnBlocks[id] == true
end

local function IsArchitrave(id)
	return ArchitraveBlocks[id] == true
end

local function IsGlowstone(id)
	return GlowstoneBlocks[id] == true
end

local function IsRainbow(id)
	-- Look up by preset flag so this works for both manually-registered presets
	-- and auto-generated reward-set presets that carry IsRainbow = true in their manifest
	for _, preset in ipairs(Presets) do
		if preset.Id == id then
			return preset.IsRainbow == true
		end
	end
	return false
end

local function IsSignStanding(id)
	return SignStandingBlocks[id] == true
end

local function IsWallSign(id)
	return WallSignBlocks[id] == true
end

local function IsSign(id)
	return SignStandingBlocks[id] == true or WallSignBlocks[id] == true
end

local function IsCrate(id)
	return CrateBlocks[id] == true
end

local function IsChest(id)
	return ChestBlocks[id] == true
end

local function IsBed(id)
	return BedBlocks[id] == true
end

local function IsCraftingTable(id)
	return CraftingTableBlocks[id] == true
end

local function IsFurnace(id)
	return id == "Furnace"
end

local function GetCraftingTableLeatherTint(id)
	if not id then return nil end
	local preset = GetPreset(id)
	if preset and preset.LeatherTint then
		return preset.LeatherTint
	end
	return nil
end

local function IsFrameBlock(id)
	return FrameBlocks[id] == true
end

local function IsArch(id)
	if not id then return false end
	local preset = GetPreset(id)
	return preset and preset.IsArch == true
end

local function IsWallpaperFrame(id)
	return id == "WallpaperFrame"
end

local function IsCarpet(id)
	return id == "CarpetFrame"
end

local function IsVine(id)
	return id == "Vine"
end

local function IsWaterBucket(id)
	local preset = GetPreset(id)
	return preset and preset.IsWaterBucket == true
end

local function IsEmptyBucket(id)
	local preset = GetPreset(id)
	return preset and preset.IsEmptyBucket == true
end

local function IsWater(id)
	return id == "Water" or id == "WaterSource" or id == "WaterFlowing"
end

-- Get placement restrictions for a decoration
-- Returns nil if no restrictions (can be placed anywhere)
-- Returns a table of allowed block types if restricted
local function GetPlacementRestrictions(id)
	return DecorationPlacementRestrictions[id]
end

-- Check if a decoration can be placed on a specific block type
-- Returns true if placement is allowed, false otherwise
local function CanPlaceDecorationOn(decorationId, blockTypeBelow)
	local restrictions = DecorationPlacementRestrictions[decorationId]
	
	-- No restrictions means it can be placed on anything
	if not restrictions then
		return true
	end
	
	-- Check if blockTypeBelow matches any of the allowed types
	for _, allowedType in ipairs(restrictions) do
		if blockTypeBelow == allowedType then
			return true
		end
	end
	
	return false
end

return {
	Shapes = Shapes,
	Presets = Presets,
	Categories = Categories,
	Colors = Colors,
	GetPreset = GetPreset,
	GetPresetsByCategory = GetPresetsByCategory,
	GetShape = GetShape,
	GetAllPresets = GetAllPresets,
	GetAllCategories = GetAllCategories,
	GetAllColors = GetAllColors,
	IsDecoration = IsDecoration,
	IsDoor = IsDoor,
	IsFence = IsFence,
	IsGlass = IsGlass,
	IsSapling = IsSapling,
	GetSaplingTreeType = GetSaplingTreeType,
	IsLadder = IsLadder,
	IsTorch = IsTorch,
	IsCampfire = IsCampfire,
	IsLantern = IsLantern,
	IsColumn = IsColumn,
	IsArchitrave = IsArchitrave,
	IsGlowstone = IsGlowstone,
	IsSignStanding = IsSignStanding,
	IsWallSign = IsWallSign,
	IsSign = IsSign,
	IsCrate = IsCrate,
	IsChest = IsChest,
	IsBed = IsBed,
	IsCraftingTable = IsCraftingTable,
	IsFurnace = IsFurnace,
	GetCraftingTableLeatherTint = GetCraftingTableLeatherTint,
	IsFrameBlock = IsFrameBlock,
	IsArch = IsArch,
	IsWallpaperFrame = IsWallpaperFrame,
	IsCarpet = IsCarpet,
	IsVine = IsVine,
	IsWaterBucket = IsWaterBucket,
	IsEmptyBucket = IsEmptyBucket,
	IsWater = IsWater,
	GetPlacementRestrictions = GetPlacementRestrictions,
	CanPlaceDecorationOn = CanPlaceDecorationOn,
	IsRainbow = IsRainbow,
}
