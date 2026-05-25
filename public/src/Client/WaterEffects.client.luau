--[[
	WaterEffects
	Client-side visual effects for water blocks.
	
	Handles:
	- Subtle wave animation on water surface (top face oscillates)
	- Transparency variation for depth/shimmer
	- Blue tint fading for deeper levels
	
	Uses CollectionService-style tagging via IsWater attribute detection.
	Performance: pools animations, uses RunService heartbeat, max active animations.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local BLOCK_SIZE = GridConfig.BLOCK_SIZE

local player = Players.LocalPlayer

-- ============================================
-- CONFIGURATION
-- ============================================

local WAVE_AMPLITUDE = 0.15        -- Max height oscillation (studs)
local WAVE_SPEED = 1.5             -- Wave cycle speed
local WAVE_SPATIAL_FREQUENCY = 0.3 -- How quickly waves vary across space
local SHIMMER_SPEED = 2.0          -- Transparency shimmer speed
local SHIMMER_AMOUNT = 0.05        -- Transparency variation (±)
local BASE_TRANSPARENCY = 0.35     -- Base transparency for source blocks
local MAX_TRANSPARENCY = 0.65      -- Max transparency for weakest flow
local MAX_ANIMATED_WATER = 200     -- Performance limit on animated water blocks
local UPDATE_RANGE_SQ = (80 * 80)  -- Only animate water within this range squared

-- ============================================
-- STATE
-- ============================================

local animatedWater = {} -- { part = true } set of tracked water parts
local animatedWaterList = {} -- Ordered list for iteration
local waterCount = 0

-- ============================================
-- WATER DETECTION
-- ============================================

local function isWaterBlock(instance)
	return instance:IsA("BasePart") and instance:GetAttribute("IsWater") == true
end

local function getWaterLevel(part)
	return part:GetAttribute("WaterLevel") or 0
end

-- ============================================
-- ADD/REMOVE WATER TRACKING
-- ============================================

local waterConnections = {} -- part -> { connection }

local function refreshWaterVisuals(part)
	local level = getWaterLevel(part)
	local isFalling = part:GetAttribute("IsFalling") or false
	local by = part:GetAttribute("BlockPosY")
	
	-- Compute correct height and Y offset from level rather than reading
	-- part.Position/Size, which may not have replicated from the server yet
	local height
	if isFalling then
		height = BLOCK_SIZE
	else
		height = BLOCK_SIZE * (8 - level) / 8
	end
	
	local yOffset = -BLOCK_SIZE / 2 + height / 2
	
	if by then
		part:SetAttribute("_WaterOrigY", by + yOffset)
	else
		part:SetAttribute("_WaterOrigY", part.Position.Y)
	end
	part:SetAttribute("_WaterOrigHeight", height)
	
	-- Also force correct Size and CFrame on the client so visuals
	-- don't flicker while waiting for server replication
	part.Size = Vector3.new(BLOCK_SIZE, height, BLOCK_SIZE)
	if by then
		local bx = part:GetAttribute("BlockPosX") or part.Position.X
		local bz = part:GetAttribute("BlockPosZ") or part.Position.Z
		part.CFrame = CFrame.new(bx, by + yOffset, bz)
	end
	
	-- Update level-based transparency
	local t = level / 7
	local transparency = BASE_TRANSPARENCY + (MAX_TRANSPARENCY - BASE_TRANSPARENCY) * t
	part.Transparency = transparency
	part:SetAttribute("_WaterBaseTransparency", transparency)
end

local function addWater(part)
	if animatedWater[part] then return end
	if waterCount >= MAX_ANIMATED_WATER then return end
	
	animatedWater[part] = true
	table.insert(animatedWaterList, part)
	waterCount += 1
	
	-- Set initial cached properties
	refreshWaterVisuals(part)
	
	-- Listen for level/falling changes (server updates during flow recalculation)
	local conns = {}
	conns[1] = part:GetAttributeChangedSignal("WaterLevel"):Connect(function()
		if part and part.Parent then
			refreshWaterVisuals(part)
		end
	end)
	conns[2] = part:GetAttributeChangedSignal("IsFalling"):Connect(function()
		if part and part.Parent then
			refreshWaterVisuals(part)
		end
	end)
	waterConnections[part] = conns
end

local function removeWater(part)
	if not animatedWater[part] then return end
	
	animatedWater[part] = nil
	waterCount -= 1
	
	-- Disconnect attribute listeners
	local conns = waterConnections[part]
	if conns then
		for _, conn in ipairs(conns) do
			conn:Disconnect()
		end
		waterConnections[part] = nil
	end
	
	-- Remove from list
	for i = #animatedWaterList, 1, -1 do
		if animatedWaterList[i] == part then
			table.remove(animatedWaterList, i)
			break
		end
	end
end

-- ============================================
-- SCAN BUILD AREAS FOR WATER
-- ============================================

local function scanForWater(folder)
	if not folder then return end
	
	for _, child in ipairs(folder:GetChildren()) do
		if isWaterBlock(child) then
			addWater(child)
		end
	end
end

local function watchFolder(folder)
	if not folder then return end
	
	scanForWater(folder)
	
	folder.ChildAdded:Connect(function(child)
		if isWaterBlock(child) then
			addWater(child)
		end
	end)
	
	folder.ChildRemoved:Connect(function(child)
		if animatedWater[child] then
			removeWater(child)
		end
	end)
end

-- Watch all build areas
local function setupWatchers()
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				watchFolder(blocksFolder)
			end
			buildArea.ChildAdded:Connect(function(child)
				if child.Name == "Blocks" and child:IsA("Folder") then
					watchFolder(child)
				end
			end)
		end
	end
	
	-- Watch for new build areas
	workspace.ChildAdded:Connect(function(child)
		if child.Name:match("^" .. GridConfig.BUILD_AREA_PREFIX .. "%d+$") then
			local blocksFolder = child:FindFirstChild("Blocks")
			if blocksFolder then
				watchFolder(blocksFolder)
			end
			child.ChildAdded:Connect(function(subChild)
				if subChild.Name == "Blocks" and subChild:IsA("Folder") then
					watchFolder(subChild)
				end
			end)
		end
	end)
	
	-- Watch MegaPlot
	local megaPlot = workspace:FindFirstChild("MegaPlotBuildArea")
	if megaPlot then
		local blocksFolder = megaPlot:FindFirstChild("Blocks")
		if blocksFolder then
			watchFolder(blocksFolder)
		end
	end
end

-- ============================================
-- ANIMATION LOOP
-- ============================================

local elapsed = 0

RunService.Heartbeat:Connect(function(dt)
	if waterCount == 0 then return end
	
	elapsed += dt
	
	local character = player.Character
	local playerPos = character and character:FindFirstChild("HumanoidRootPart")
	local playerPosition = playerPos and playerPos.Position or Vector3.zero
	
	-- Iterate backwards for safe removal
	for i = #animatedWaterList, 1, -1 do
		local part = animatedWaterList[i]
		
		-- Check if part still exists
		if not part or not part.Parent then
			removeWater(part)
			continue
		end
		
		-- Range check (skip distant water)
		local delta = part.Position - playerPosition
		local distSq = delta.X * delta.X + delta.Z * delta.Z
		if distSq > UPDATE_RANGE_SQ then
			continue
		end
		
		local level = getWaterLevel(part)
		local origY = part:GetAttribute("_WaterOrigY")
		local origHeight = part:GetAttribute("_WaterOrigHeight")
		local baseTransparency = part:GetAttribute("_WaterBaseTransparency") or BASE_TRANSPARENCY
		
		if not origY or not origHeight then continue end
		
		-- Wave animation (only for top surface - source and level 1)
		if level <= 1 then
			local spatialOffset = part.Position.X * WAVE_SPATIAL_FREQUENCY + part.Position.Z * WAVE_SPATIAL_FREQUENCY * 0.7
			local wave = math.sin(elapsed * WAVE_SPEED + spatialOffset) * WAVE_AMPLITUDE
			
			-- Adjust Y position slightly (keep bottom anchored)
			local newY = origY + wave * 0.5
			part.CFrame = CFrame.new(part.Position.X, newY, part.Position.Z)
		end
		
		-- Transparency shimmer
		local shimmer = math.sin(elapsed * SHIMMER_SPEED + part.Position.X * 0.5) * SHIMMER_AMOUNT
		part.Transparency = math.clamp(baseTransparency + shimmer, 0.1, 0.9)
	end
end)

-- ============================================
-- INITIALIZE
-- ============================================

-- Delay slightly to let build areas load
task.delay(2, function()
	setupWatchers()
	print("[WaterEffects] Initialized - watching for water blocks")
end)
