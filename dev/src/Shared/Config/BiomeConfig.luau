--[[
	BiomeConfig
	Defines different biomes and their properties
]]

local BiomeConfig = {}

-- (TerrainStyles defined below after biome data)

-- Tree wood color variants
BiomeConfig.WoodTypes = {
	Oak = {
		BarkColor = Color3.fromRGB(111, 85, 65),  -- Warm brown bark
		WoodColor = Color3.fromRGB(195, 155, 105),  -- Light tan wood
	},
	Spruce = {
		BarkColor = Color3.fromRGB(85, 65, 50),  -- Darker brown
		WoodColor = Color3.fromRGB(165, 130, 90),  -- Darker tan
	},
	Birch = {
		BarkColor = Color3.fromRGB(225, 220, 210),  -- White/cream bark
		WoodColor = Color3.fromRGB(205, 180, 135),  -- Light wood
	},
	Acacia = {
		BarkColor = Color3.fromRGB(105, 90, 75),  -- Grayish-brown bark
		WoodColor = Color3.fromRGB(175, 95, 55),  -- Orange-red heartwood
	},
	DarkOak = {
		BarkColor = Color3.fromRGB(55, 40, 30),  -- Very dark brown bark
		WoodColor = Color3.fromRGB(75, 55, 40),  -- Dark brown wood
	},
	Ebony = {
		BarkColor = Color3.fromRGB(35, 30, 25),  -- Nearly black bark
		WoodColor = Color3.fromRGB(25, 20, 15),  -- Very dark/black wood
	},
	Redwood = {
		BarkColor = Color3.fromRGB(140, 65, 45),  -- Reddish-brown bark
		WoodColor = Color3.fromRGB(165, 85, 55),  -- Rich red-brown wood
	},
}

-- Leaf color variants (base colors per tree type)
BiomeConfig.LeafTypes = {
	Oak = {
		Color = Color3.fromRGB(85, 140, 55),  -- Bright green
	},
	Spruce = {
		Color = Color3.fromRGB(50, 95, 50),  -- Dark forest green (evergreen)
	},
	Birch = {
		Color = Color3.fromRGB(155, 185, 85),  -- Yellowish-green (birch leaves are lighter)
	},
	Acacia = {
		Color = Color3.fromRGB(105, 155, 45),  -- Yellow-green (savanna style)
	},
	DarkOak = {
		Color = Color3.fromRGB(45, 95, 35),  -- Dark rich green
	},
	Ebony = {
		Color = Color3.fromRGB(35, 105, 45),  -- Deep tropical green
	},
	Redwood = {
		Color = Color3.fromRGB(55, 85, 45),  -- Dark blue-green (conifer needles)
	},
}

-- Season color modifiers (multiplied with biome colors)
-- Applied on top of biome colors for seasonal effects
-- Values below 1.0 reduce that channel, above 1.0 boost it
BiomeConfig.SeasonColors = {
	Spring = {
		GrassMultiplier = Color3.new(0.7, 1.2, 0.7),   -- Bright vibrant green
		LeafMultiplier = Color3.new(0.8, 1.3, 0.6),    -- Fresh light green leaves
		DecorationMultiplier = Color3.new(0.7, 1.2, 0.7), -- Same as grass for consistency
	},
	Summer = {
		GrassMultiplier = Color3.new(1, 1, 1),         -- Normal (no change)
		LeafMultiplier = Color3.new(1, 1, 1),
		DecorationMultiplier = Color3.new(1, 1, 1),    -- Same as grass for consistency
	},
	Autumn = {
		GrassMultiplier = Color3.new(1.4, 0.85, 0.4),  -- Yellow-brown dying grass
		LeafMultiplier = Color3.new(1.6, 0.45, 0.15),  -- Strong orange/red leaves (default for oak etc)
		DecorationMultiplier = Color3.new(1.4, 0.85, 0.4), -- Same as grass for consistency
	},
	Winter = {
		GrassMultiplier = Color3.new(1.1, 0.85, 0.6),  -- Light tan/brown dead grass
		LeafMultiplier = Color3.new(0.9, 0.7, 0.5),    -- Pale brown dead leaves
		DecorationMultiplier = Color3.new(1.1, 0.85, 0.6), -- Same as grass for consistency
	},
}

-- Tree-type-specific seasonal overrides
-- These override the default LeafMultiplier for specific tree types
-- Use "EVERGREEN" marker to indicate tree should NOT change with seasons
BiomeConfig.TreeSeasonOverrides = {
	Birch = {
		Autumn = Color3.fromRGB(255, 220, 50),  -- Bright golden yellow (direct color, not multiplier)
		Winter = Color3.fromRGB(210, 180, 100), -- Pale yellow-brown
	},
	Spruce = {
		-- Spruce trees are evergreens - they keep their needles year-round
		Evergreen = true,
	},
	Acacia = {
		Autumn = Color3.fromRGB(205, 175, 45),  -- Golden yellow
		Winter = Color3.fromRGB(165, 135, 75),  -- Tan/brown (savanna dry season)
	},
	DarkOak = {
		Autumn = Color3.fromRGB(165, 55, 25),   -- Deep red/burgundy
		Winter = Color3.fromRGB(95, 55, 35),    -- Dark brown
	},
	Ebony = {
		-- Tropical evergreen, doesn't change much
		Evergreen = true,
	},
	Redwood = {
		-- Redwood trees are evergreen conifers - they keep their needles year-round
		Evergreen = true,
	},
}

-- Helper function to apply a color multiplier
-- Multiplier values: 1.0 = no change, <1.0 = reduce, >1.0 = boost
local function applyColorMultiplier(baseColor, multiplier)
	if not multiplier then
		return baseColor
	end
	
	-- Check if it's effectively no change (1, 1, 1)
	if math.abs(multiplier.R - 1) < 0.01 and math.abs(multiplier.G - 1) < 0.01 and math.abs(multiplier.B - 1) < 0.01 then
		return baseColor
	end
	
	-- Multiply each channel and clamp to valid range
	return Color3.new(
		math.clamp(baseColor.R * multiplier.R, 0, 1),
		math.clamp(baseColor.G * multiplier.G, 0, 1),
		math.clamp(baseColor.B * multiplier.B, 0, 1)
	)
end

-- Get season color config
function BiomeConfig.GetSeasonColors(seasonName)
	return BiomeConfig.SeasonColors[seasonName] or BiomeConfig.SeasonColors.Summer
end

-- Get list of available season names
function BiomeConfig.GetSeasonNames()
	return {"Spring", "Summer", "Autumn", "Winter"}
end

-- Default season
BiomeConfig.DefaultSeason = "Summer"

-- Biome color tints (applied to grass and vegetation)
-- These tint the grass part of GrassBlock and blend with leaf colors
BiomeConfig.BiomeColors = {
	Plains = {
		GrassColor = Color3.fromRGB(145, 189, 89),  -- Bright yellow-green (default Minecraft look)
		LeafTint = Color3.fromRGB(119, 171, 47),
	},
	Forest = {
		GrassColor = Color3.fromRGB(89, 145, 55),   -- Darker, richer forest green
		LeafTint = Color3.fromRGB(60, 135, 45),
	},
	Taiga = {
		GrassColor = Color3.fromRGB(120, 150, 110), -- Muted grayish-green (cold)
		LeafTint = Color3.fromRGB(75, 110, 70),
	},
	Swamp = {
		GrassColor = Color3.fromRGB(95, 115, 45),   -- Dark murky olive-brown
		LeafTint = Color3.fromRGB(85, 105, 40),
	},
	Desert = {
		GrassColor = nil,  -- No grass tinting (uses sand)
		LeafTint = Color3.fromRGB(174, 164, 42),
	},
	Mountains = {
		GrassColor = Color3.fromRGB(115, 135, 95),  -- Rocky gray-green
		LeafTint = Color3.fromRGB(85, 115, 70),
	},
	Snowy = {
		GrassColor = Color3.fromRGB(95, 155, 115),  -- Frost-touched teal-green
		LeafTint = Color3.fromRGB(70, 120, 85),
	},
	BirchForest = {
		GrassColor = Color3.fromRGB(120, 170, 75),  -- Light yellow-green
		LeafTint = Color3.fromRGB(100, 160, 55),
	},
	Flat = {
		GrassColor = Color3.fromRGB(145, 189, 89),  -- Default (same as Plains)
		LeafTint = Color3.fromRGB(119, 171, 47),
	},
}

-- Helper function to get biome colors
function BiomeConfig.GetBiomeColors(biomeName)
	return BiomeConfig.BiomeColors[biomeName] or BiomeConfig.BiomeColors.Plains
end

-- Helper function to blend leaf color with biome tint
function BiomeConfig.GetTintedLeafColor(leafType, biomeName)
	local leafConfig = BiomeConfig.LeafTypes[leafType] or BiomeConfig.LeafTypes.Oak
	local biomeColors = BiomeConfig.GetBiomeColors(biomeName)
	
	if not biomeColors.LeafTint then
		return leafConfig.Color
	end
	
	-- Blend the tree's base color with the biome tint (70% tree, 30% biome)
	local baseColor = leafConfig.Color
	local tint = biomeColors.LeafTint
	
	return Color3.new(
		baseColor.R * 0.7 + tint.R * 0.3,
		baseColor.G * 0.7 + tint.G * 0.3,
		baseColor.B * 0.7 + tint.B * 0.3
	)
end

-- Helper function to add random variation to a color
-- This makes vegetation look more natural and less uniform
-- Hue: ±0.5% variation (very slight color shift)
-- Saturation: ±2% variation (subtle vibrancy change)
-- Value/Brightness: ±2.5% variation (subtle light/dark)
function BiomeConfig.GetRandomizedColor(baseColor)
	local h, s, v = Color3.toHSV(baseColor)
	
	local hueVariation = (math.random() - 0.5) * 0.01  -- ±0.5%
	local satVariation = (math.random() - 0.5) * 0.04  -- ±2%
	local valVariation = (math.random() - 0.5) * 0.05  -- ±2.5%
	
	local newH = math.clamp(h + hueVariation, 0, 1)
	local newS = math.clamp(s + satVariation, 0.3, 1)
	local newV = math.clamp(v + valVariation, 0.3, 1)
	
	return Color3.fromHSV(newH, newS, newV)
end

-- Leaf color randomization - more dramatic variation for natural tree canopies
function BiomeConfig.GetRandomizedLeafColor(baseColor)
	local h, s, v = Color3.toHSV(baseColor)
	
	-- More noticeable variation for leaves
	-- Hue: ±2% variation (color shift between yellow-green and blue-green)
	-- Saturation: ±8% variation (some leaves more vibrant, some muted)
	-- Value/Brightness: ±12% variation (light/shadow variation in canopy)
	local hueVariation = (math.random() - 0.5) * 0.04  -- ±2%
	local satVariation = (math.random() - 0.5) * 0.16  -- ±8%
	local valVariation = (math.random() - 0.5) * 0.24  -- ±12%
	
	local newH = math.clamp(h + hueVariation, 0, 1)
	local newS = math.clamp(s + satVariation, 0.25, 1)
	local newV = math.clamp(v + valVariation, 0.25, 1)
	
	return Color3.fromHSV(newH, newS, newV)
end

-- Grass color randomization - ONLY brightness variation for subtlety
-- Optional season parameter applies seasonal tint
function BiomeConfig.GetRandomizedGrassColor(baseColor, seasonName)
	-- Apply season multiplier first if provided
	local colorToUse = baseColor
	if seasonName then
		local seasonColors = BiomeConfig.GetSeasonColors(seasonName)
		if seasonColors.GrassMultiplier then
			colorToUse = applyColorMultiplier(baseColor, seasonColors.GrassMultiplier)
		end
	end
	
	local h, s, v = Color3.toHSV(colorToUse)
	
	-- Only vary brightness, keep hue and saturation the same
	local valVariation = (math.random() - 0.5) * 0.05  -- ±2.5%
	local newV = math.clamp(v + valVariation, 0.3, 1)
	
	return Color3.fromHSV(h, s, newV)
end

-- Helper function to get a randomized tinted leaf color (combines biome tint + random variation)
-- Optional season parameter applies seasonal tint (autumn leaves, etc.)
-- leafType parameter allows tree-specific seasonal colors (e.g., birch = yellow in autumn)
-- Evergreen trees (Spruce, Redwood, Ebony) keep their color year-round
function BiomeConfig.GetRandomizedTintedLeafColor(leafType, biomeName, seasonName)
	local tintedColor = BiomeConfig.GetTintedLeafColor(leafType, biomeName)
	
	-- Check for tree-type-specific seasonal override first
	if seasonName and leafType then
		local treeOverrides = BiomeConfig.TreeSeasonOverrides[leafType]
		if treeOverrides then
			-- Check if this tree is evergreen (no seasonal color change)
			if treeOverrides.Evergreen then
				-- Skip seasonal coloring entirely for evergreens
				return BiomeConfig.GetRandomizedLeafColor(tintedColor)
			end
			
			-- Check for specific seasonal color override
			if treeOverrides[seasonName] then
				-- Use direct color override (not multiplier) for this tree type
				tintedColor = treeOverrides[seasonName]
				return BiomeConfig.GetRandomizedLeafColor(tintedColor)
			end
		end
	end
	
	-- Fall back to default season multiplier
	if seasonName then
		local seasonColors = BiomeConfig.GetSeasonColors(seasonName)
		if seasonColors.LeafMultiplier then
			tintedColor = applyColorMultiplier(tintedColor, seasonColors.LeafMultiplier)
		end
	end
	
	return BiomeConfig.GetRandomizedLeafColor(tintedColor)
end

-- Get seasonal decoration color (for grass decorations like TallGrass, ShortGrass)
function BiomeConfig.GetSeasonalDecorationColor(baseColor, seasonName)
	if not seasonName then
		return baseColor
	end
	
	local seasonColors = BiomeConfig.GetSeasonColors(seasonName)
	if seasonColors.DecorationMultiplier then
		return applyColorMultiplier(baseColor, seasonColors.DecorationMultiplier)
	end
	
	return baseColor
end

-- Biome definitions
BiomeConfig.Biomes = {
	Flat = {
		DisplayName = "Flat",
		Description = "Empty flat terrain - perfect for building",
		SortOrder = 1,
		GrassBlock = "GrassBlock",
		DirtBlock = "Dirt",
		TreeTypes = {},
		TreeDensity = 0,
		Decorations = {},
		NoiseScale = 0,
		NoiseAmplitude = 0,
		NoiseOctaves = 0,
	},
	
	Plains = {
		DisplayName = "Plains",
		Description = "Wide open grasslands with gentle hills and rare trees",
		SortOrder = 2,
		GrassBlock = "GrassBlock",
		DirtBlock = "Dirt",
		TreeTypes = {"Oak"},
		TreeDensity = 0.005,
		Decorations = {
			{Type = "ShortGrass", Chance = 0.10},
			{Type = "TallGrass", Chance = 0.03},
			{Type = "OrangeFlower", Chance = 0.015},
			{Type = "PinkFlower", Chance = 0.015},
			{Type = "RedFlower", Chance = 0.015},
			{Type = "WhiteFlower", Chance = 0.015},
		},
		NoiseScale = 0.015,
		NoiseAmplitude = 2,
		NoiseOctaves = 2,
		SmoothingPasses = 2,
		ContinentalScale = 0.003,
		ContinentalAmplitude = 2,
	},
	
	Forest = {
		DisplayName = "Forest",
		Description = "Dense woodland with many trees",
		SortOrder = 3,
		GrassBlock = "GrassBlock",
		DirtBlock = "Dirt",
		TreeTypes = {"Oak", "Birch"},
		TreeDensity = 0.06,
		Decorations = {
			{Type = "ShortGrass", Chance = 0.12},
			{Type = "TallGrass", Chance = 0.05},
			{Type = "OrangeFlower", Chance = 0.02},
			{Type = "PinkFlower", Chance = 0.02},
			{Type = "RedFlower", Chance = 0.025},
			{Type = "WhiteFlower", Chance = 0.02},
		},
		NoiseScale = 0.018,
		NoiseAmplitude = 6,
		NoiseOctaves = 3,
		SmoothingPasses = 1,
		ContinentalScale = 0.005,
		ContinentalAmplitude = 4,
	},
	
	BirchForest = {
		DisplayName = "Birch Forest",
		Description = "Light woodland with birch trees and fallen logs",
		SortOrder = 4,
		GrassBlock = "GrassBlock",
		DirtBlock = "Dirt",
		TreeTypes = {"Birch"},
		TreeDensity = 0.055,
		FallenLogTypes = {"HollowBirchLog", "BirchLog"},  -- Fallen logs scattered on ground
		FallenLogDensity = 0.015,  -- Chance per block to spawn a fallen log
		Decorations = {
			{Type = "ShortGrass", Chance = 0.14},
			{Type = "TallGrass", Chance = 0.06},
			{Type = "WhiteFlower", Chance = 0.03},
			{Type = "PinkFlower", Chance = 0.02},
		},
		NoiseScale = 0.015,
		NoiseAmplitude = 5,
		NoiseOctaves = 3,
		SmoothingPasses = 1,
		ContinentalScale = 0.005,
		ContinentalAmplitude = 3,
	},
	
	Taiga = {
		DisplayName = "Taiga",
		Description = "Cold spruce forest",
		SortOrder = 5,
		GrassBlock = "GrassBlock",
		DirtBlock = "Dirt",
		TreeTypes = {"Spruce"},
		TreeDensity = 0.05,
		Decorations = {
			{Type = "ShortGrass", Chance = 0.08},
			{Type = "TallGrass", Chance = 0.02},
			{Type = "WhiteFlower", Chance = 0.01},
		},
		NoiseScale = 0.016,
		NoiseAmplitude = 7,
		NoiseOctaves = 3,
		SmoothingPasses = 1,
		ContinentalScale = 0.004,
		ContinentalAmplitude = 5,
	},
	
	Desert = {
		DisplayName = "Desert",
		Description = "Sandy dunes with cacti",
		SortOrder = 6,
		GrassBlock = "Sand",
		DirtBlock = "Sand",
		TreeTypes = {},
		TreeDensity = 0,
		CactusDensity = 0.004,    -- Chance per block to spawn a cactus column
		CactusMinHeight = 1,      -- Minimum cactus height in blocks
		CactusMaxHeight = 4,      -- Maximum cactus height in blocks
		CactusMinSpacing = 8,     -- Minimum blocks between cacti
		Decorations = {
			{Type = "DeadBush", Chance = 0.02},
		},
		NoiseScale = 0.012,
		NoiseAmplitude = 4,
		NoiseOctaves = 3,
		SmoothingPasses = 2,
		TerrainShape = "dunes",  -- Smooth rolling dunes
		ContinentalScale = 0.003,
		ContinentalAmplitude = 3,  -- Deserts are relatively flat with gentle broad undulations
	},
	
	Swamp = {
		DisplayName = "Swamp",
		Description = "Murky wetlands with vines",
		SortOrder = 7,
		GrassBlock = "GrassBlock",
		DirtBlock = "Dirt",
		TreeTypes = {"Oak"},
		TreeDensity = 0.04,
		Decorations = {
			{Type = "TallGrass", Chance = 0.15},
			{Type = "ShortGrass", Chance = 0.08},
			{Type = "LilyPad", Chance = 0.03},
		},
		NoiseScale = 0.01,
		NoiseAmplitude = 2,
		NoiseOctaves = 3,
		SmoothingPasses = 2,
		WaterLevel = 2,  -- Shallow water pools
		ContinentalScale = 0.003,
		ContinentalAmplitude = 2,  -- Swamps are very flat with subtle undulation
	},
	
	Mountains = {
		DisplayName = "Mountains",
		Description = "Steep rocky peaks",
		SortOrder = 8,
		GrassBlock = "Stone",
		DirtBlock = "Stone",
		TreeTypes = {"Spruce"},
		TreeDensity = 0.01,
		Decorations = {
			{Type = "ShortGrass", Chance = 0.03},
		},
		NoiseScale = 0.012,
		NoiseAmplitude = 14,
		NoiseOctaves = 4,
		SmoothingPasses = 1,  -- Less smoothing for dramatic peaks
		TerrainShape = "ridged",  -- Creates ridged mountain profiles instead of random spikes
		ContinentalScale = 0.004,
		ContinentalAmplitude = 8,  -- Big broad mountain ranges
	},
	
	Snowy = {
		DisplayName = "Snowy",
		Description = "Frozen tundra with snow",
		SortOrder = 9,
		GrassBlock = "Snow",
		DirtBlock = "Dirt",
		TreeTypes = {"Spruce"},
		TreeDensity = 0.02,
		Decorations = {
			{Type = "ShortGrass", Chance = 0.02},
		},
		NoiseScale = 0.018,
		NoiseAmplitude = 6,
		NoiseOctaves = 3,
		SmoothingPasses = 1,
		ContinentalScale = 0.004,
		ContinentalAmplitude = 4,
	},
}

-- ============================================
-- BIOME TEMPERATURE CLUSTERING (for Default terrain)
-- ============================================

-- Temperature categories for biome clustering
-- Warm biomes spawn near warm, cool near cool, temperate borders either
BiomeConfig.BiomeTemperatures = {
	Desert = "hot",
	Plains = "warm",
	Swamp = "warm",
	Forest = "temperate",
	BirchForest = "temperate",
	Taiga = "cold",
	Mountains = "cold",
	Snowy = "cold",
}

-- Get biomes compatible with a given biome (same temp or temperate bridge)
function BiomeConfig.GetCompatibleBiomes(biomeName)
	local temp = BiomeConfig.BiomeTemperatures[biomeName]
	if not temp then return {biomeName} end
	
	local compatible = {}
	for name, biomeTemp in pairs(BiomeConfig.BiomeTemperatures) do
		-- Same temperature, or temperate can border anything, or anything can border temperate
		if biomeTemp == temp or biomeTemp == "temperate" or temp == "temperate" then
			table.insert(compatible, name)
		end
	end
	return compatible
end

-- Get all non-Flat biome names for Default terrain generation
function BiomeConfig.GetGeneratableBiomeNames()
	local names = {}
	for name, _ in pairs(BiomeConfig.BiomeTemperatures) do
		table.insert(names, name)
	end
	return names
end

-- Terrain style options (updated for 3-mode system)
BiomeConfig.TerrainStyles = {
	Flat = {
		DisplayName = "Flat",
		Description = "Completely flat terrain",
	},
	Default = {
		DisplayName = "Default",
		Description = "Random multi-biome world segment",
	},
	Biome = {
		DisplayName = "Biome",
		Description = "Choose a specific biome",
	},
}

-- Default biome if none selected
BiomeConfig.DefaultBiome = "Plains"
BiomeConfig.DefaultTerrainStyle = "Default"

-- Get biome config by name
function BiomeConfig.GetBiome(biomeName)
	return BiomeConfig.Biomes[biomeName] or BiomeConfig.Biomes[BiomeConfig.DefaultBiome]
end

-- Get list of biome names
function BiomeConfig.GetBiomeNames()
	local names = {}
	for name, _ in pairs(BiomeConfig.Biomes) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- Tint a leaf block to `leafColor` WITHOUT recolouring its bark. A leaf block shows
-- its colour on the part(s) plus a face Texture/Decal overlay; the "Branches" texture
-- (and any dedicated "Branches" part) keeps its own authored bark tint so that shearing
-- the leaves reveals correctly-coloured branches. Used on placement (BlockHandler),
-- on load (SaveManager / MegaPlotSaveManager) and by TreeGenerator.
function BiomeConfig.TintLeaves(block, leafColor)
	if not block or not leafColor then return end
	local function tintPart(part)
		-- A dedicated "Branches" BasePart (if a model has one) keeps its bark colour.
		if part.Name ~= "Branches" then
			part.Color = leafColor
		end
		for _, d in ipairs(part:GetChildren()) do
			-- Tint the leaf face overlay(s) only; leave the "Branches" texture's tint alone.
			if (d:IsA("Texture") or d:IsA("Decal")) and d.Name ~= "Branches" then
				d.Color3 = leafColor
			end
		end
	end
	if block:IsA("BasePart") then
		tintPart(block)
	else
		for _, p in ipairs(block:GetDescendants()) do
			if p:IsA("BasePart") then tintPart(p) end
		end
	end
end

return BiomeConfig
