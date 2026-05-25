--[[
	SeasonManager
	Handles per-plot seasonal effects including colors, decorations, and particles
	
	Season Types:
	- Spring: Bright greens, flower particles
	- Summer: Vibrant colors, default
	- Autumn: Orange/red tints, falling leaves
	- Winter: White/blue tints, frost effects
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local SeasonManager = {}

-- Store active season per plot
local PlotSeason = {}
local PlotSeasonEffects = {}

-- Season color modifiers for different block types
local SeasonConfig = {
	Spring = {
		GrassMultiplier = Color3.fromRGB(130, 255, 130), -- Bright green
		LeafMultiplier = Color3.fromRGB(150, 255, 150), -- Light green leaves
		HasFlowerParticles = true,
		FlowerRate = 5,
		FlowerColors = {
			Color3.fromRGB(255, 150, 200), -- Pink
			Color3.fromRGB(255, 255, 150), -- Yellow
			Color3.fromRGB(200, 150, 255), -- Purple
			Color3.fromRGB(255, 200, 200), -- Light pink
		},
	},
	Summer = {
		GrassMultiplier = Color3.fromRGB(255, 255, 255), -- Normal
		LeafMultiplier = Color3.fromRGB(255, 255, 255), -- Normal
		HasFlowerParticles = false,
	},
	Autumn = {
		GrassMultiplier = Color3.fromRGB(255, 220, 180), -- Yellowish grass
		LeafMultiplier = Color3.fromRGB(255, 150, 80), -- Orange/red leaves
		HasLeafParticles = true,
		LeafRate = 15,
		LeafColors = {
			Color3.fromRGB(255, 100, 50), -- Orange
			Color3.fromRGB(255, 180, 50), -- Yellow-orange
			Color3.fromRGB(200, 80, 40), -- Red-brown
			Color3.fromRGB(180, 120, 60), -- Brown
		},
	},
	Winter = {
		GrassMultiplier = Color3.fromRGB(220, 230, 255), -- Frost tint
		LeafMultiplier = Color3.fromRGB(180, 200, 220), -- Frosty leaves (or bare)
		HasSnowLayer = true,
		SnowAccumulation = 0.2, -- How much snow accumulates on surfaces
	},
}

-- Helper to convert Color3 array to ColorSequence with evenly distributed keypoints
local function colorsToSequence(colors)
	if not colors or #colors == 0 then
		return ColorSequence.new(Color3.new(1, 1, 1))
	end
	
	if #colors == 1 then
		return ColorSequence.new(colors[1])
	end
	
	local keypoints = {}
	for i, color in ipairs(colors) do
		local time = (i - 1) / (#colors - 1)
		table.insert(keypoints, ColorSequenceKeypoint.new(time, color))
	end
	
	return ColorSequence.new(keypoints)
end

-- Create seasonal particle emitter for a plot
local function createSeasonalEmitter(buildArea, seasonType)
	local config = SeasonConfig[seasonType]
	if not config then return nil end
	
	local hasParticles = config.HasFlowerParticles or config.HasLeafParticles
	if not hasParticles then return nil end
	
	-- Get plot bounds
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX") or 100
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ") or 100
	local surfaceY = buildArea:GetAttribute("TerrainSurfaceY") or 5
	
	if not posX or not posZ then return nil end
	
	-- Create emitter part
	local emitterPart = Instance.new("Part")
	emitterPart.Name = "SeasonEmitter"
	emitterPart.Size = Vector3.new(sizeX, 1, sizeZ)
	emitterPart.Position = Vector3.new(posX, surfaceY + 30, posZ)
	emitterPart.Anchored = true
	emitterPart.CanCollide = false
	emitterPart.CanQuery = false
	emitterPart.Transparency = 1
	emitterPart.Parent = buildArea
	
	if config.HasFlowerParticles then
		-- Flower petal particles floating upward
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "FlowerParticles"
		emitter.Rate = config.FlowerRate
		emitter.Color = colorsToSequence(config.FlowerColors)
		emitter.Speed = NumberRange.new(1, 3)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(0.5, 0.4),
			NumberSequenceKeypoint.new(1, 0.2),
		})
		emitter.Lifetime = NumberRange.new(6, 10)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.RotSpeed = NumberRange.new(-60, 60)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.Drag = 3
		emitter.Texture = "rbxassetid://243660364" -- Soft particle
		emitter.LightEmission = 0.2
		emitter.Parent = emitterPart
		
	elseif config.HasLeafParticles then
		-- Falling leaves
		local emitter = Instance.new("ParticleEmitter")
		emitter.Name = "LeafParticles"
		emitter.Rate = config.LeafRate
		emitter.Color = colorsToSequence(config.LeafColors)
		emitter.Speed = NumberRange.new(3, 8)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(0.5, 0.6),
			NumberSequenceKeypoint.new(1, 0.4),
		})
		emitter.Lifetime = NumberRange.new(5, 8)
		emitter.SpreadAngle = Vector2.new(45, 45)
		emitter.EmissionDirection = Enum.NormalId.Bottom
		emitter.RotSpeed = NumberRange.new(-120, 120)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.Drag = 4 -- Slow falling, floaty
		emitter.Texture = "rbxassetid://2714866393" -- Leaf texture
		emitter.LightEmission = 0
		emitter.Parent = emitterPart
	end
	
	return emitterPart
end

-- Apply snow accumulation effect to blocks (simplified - adds white overlay)
local function applyWinterEffect(buildArea)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	-- This is a visual hint - actual snow blocks would be added during terrain gen
	-- For now we just tint existing blocks slightly
	-- Full implementation would clone and modify block appearances
end

-- Apply seasonal color tint to a specific block (for future per-block coloring)
local function applySeasonTint(block, seasonType)
	local config = SeasonConfig[seasonType]
	if not config then return end
	
	local blockType = block:GetAttribute("BlockType")
	if not blockType then return end
	
	-- Could modify block colors here based on type
	-- For now, seasonal effects are primarily particles
end

-- Clear season effects for a plot
local function clearSeasonEffects(plotNumber)
	local effects = PlotSeasonEffects[plotNumber]
	if not effects then return end
	
	if effects.emitter then
		effects.emitter:Destroy()
		effects.emitter = nil
	end
	
	PlotSeasonEffects[plotNumber] = nil
end

-- Set season for a plot
function SeasonManager.SetSeason(buildArea, plotNumber, seasonType)
	if not buildArea or not plotNumber then return end
	if not SeasonConfig[seasonType] then
		seasonType = "Summer"
	end
	
	-- Check if season is actually changing
	local previousSeason = PlotSeason[plotNumber]
	local seasonChanged = previousSeason ~= seasonType
	
	-- Clear existing effects
	clearSeasonEffects(plotNumber)
	
	-- Store new season
	PlotSeason[plotNumber] = seasonType
	buildArea:SetAttribute("CurrentSeason", seasonType)
	
	-- Create new effects
	PlotSeasonEffects[plotNumber] = {}
	local effects = PlotSeasonEffects[plotNumber]
	
	-- Create emitter
	effects.emitter = createSeasonalEmitter(buildArea, seasonType)
	
	-- Apply winter snow effect
	if seasonType == "Winter" then
		applyWinterEffect(buildArea)
	end
	
	-- Update existing block colors if season changed (live color update)
	if seasonChanged then
		task.spawn(function()
			SeasonManager.UpdatePlotColors(buildArea, plotNumber, seasonType)
		end)
	end
	
	print("[SeasonManager] Set season to " .. seasonType .. " for plot " .. plotNumber)
end

-- Get current season for a plot
function SeasonManager.GetSeason(plotNumber)
	return PlotSeason[plotNumber] or "Summer"
end

-- Clean up when plot is released
function SeasonManager.ClearPlot(plotNumber)
	clearSeasonEffects(plotNumber)
	PlotSeason[plotNumber] = nil
end

-- Get season config (for terrain generation modifications)
function SeasonManager.GetSeasonConfig(seasonType)
	return SeasonConfig[seasonType]
end

-- Update all block colors in a plot to match the new season
-- This is called when the player changes seasons
function SeasonManager.UpdatePlotColors(buildArea, plotNumber, seasonType)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	local BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
	local biomeName = buildArea:GetAttribute("CurrentBiome") or "Plains"
	
	local biomeColors = BiomeConfig.GetBiomeColors(biomeName)
	if not biomeColors then return end
	
	local blocksUpdated = 0
	local decorationsUpdated = 0
	local leavesUpdated = 0
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockType = block:GetAttribute("BlockType")
		
		-- Update grass blocks
		if blockType == "GrassBlock" or blockType == "SnowGrassBlock" or blockType == "TaigaGrassBlock" then
			if biomeColors.GrassColor then
				local grassColor = BiomeConfig.GetRandomizedGrassColor(biomeColors.GrassColor, seasonType)
				
				if block:IsA("Model") then
					local grassPart = block:FindFirstChild("Grass")
					if grassPart and grassPart:IsA("BasePart") then
						grassPart.Color = grassColor
					end
				elseif block:IsA("BasePart") then
					block.Color = grassColor
				end
				
				block:SetAttribute("Season", seasonType)
				blocksUpdated = blocksUpdated + 1
			end
			
		-- Update grass decorations (ShortGrass, TallGrass) - should match GRASS colors, not leaves
		elseif blockType == "ShortGrass" or blockType == "TallGrass" then
			if biomeColors.GrassColor then
				-- Use grass multiplier, not decoration multiplier (which was too leaf-like)
				local grassColor = BiomeConfig.GetRandomizedGrassColor(biomeColors.GrassColor, seasonType)
				
				if block:IsA("BasePart") then
					block.Color = grassColor
				elseif block:IsA("Model") then
					for _, part in ipairs(block:GetDescendants()) do
						if part:IsA("BasePart") then
							part.Color = grassColor
						end
					end
				end
				
				block:SetAttribute("Season", seasonType)
				decorationsUpdated = decorationsUpdated + 1
			end
			
		-- Update leaves
		elseif blockType == "Leaves" then
			local treeType = block:GetAttribute("TreeType") or "Oak"
			local leafColor = BiomeConfig.GetRandomizedTintedLeafColor(treeType, biomeName, seasonType)
			
			if block:IsA("BasePart") then
				block.Color = leafColor
			elseif block:IsA("Model") then
				for _, part in ipairs(block:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Color = leafColor
					end
				end
			end
			
			block:SetAttribute("Season", seasonType)
			leavesUpdated = leavesUpdated + 1
		end
		
		-- Yield periodically to avoid freezing
		if (blocksUpdated + decorationsUpdated + leavesUpdated) % 100 == 0 then
			task.wait()
		end
	end
	
	print(string.format("[SeasonManager] Updated colors for %s: %d blocks, %d decorations, %d leaves",
		seasonType, blocksUpdated, decorationsUpdated, leavesUpdated))
end

return SeasonManager
