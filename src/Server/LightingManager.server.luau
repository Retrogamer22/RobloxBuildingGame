--[[
	LightingManager
	Server-side light blowout prevention system
	
	Monitors all light sources (PointLight, SpotLight, SurfaceLight) across build areas.
	When multiple lights overlap, dynamically scales their brightness down so the
	combined illumination stays even and doesn't blow out surrounding areas.
	
	Uses TweenService for smooth brightness transitions - no flicker or popping.
	
	Stores original brightness as an attribute and recalculates whenever lights are
	added, removed, or toggled (e.g. lamps via IsPowered).
	
	Respects BulkOperationFlags to defer recalculation during terrain gen/save loads.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))

-- ============================================
-- CONFIGURATION
-- ============================================

local CONFIG = {
	-- How aggressively to reduce brightness when lights overlap
	-- Lower = more aggressive reduction. 0.5 = sqrt, 0.65 = balanced, 1.0 = linear (harsh)
	ScalePower = 0.6,
	
	-- Minimum brightness any light can be reduced to (fraction of original)
	MinBrightnessFraction = 0.15,
	
	-- Dense cluster settings: extra reduction when many lights are packed tightly
	DenseClusterThreshold = 3,    -- Overlap count above which dense scaling kicks in
	DenseClusterPower = 0.35,     -- Additional scale power for the dense portion (aggressive)
	DenseMinBrightnessFraction = 0.03, -- Absolute floor for dense clusters (3% of original)
	
	-- How far beyond a light's range to consider overlaps (multiplier on range)
	OverlapThreshold = 0.85,
	
	-- Debounce time (seconds) before recalculating after a change
	RecalcDebounce = 0.1,
	
	-- How often to check for pending bulk operation completions (seconds)
	BulkCheckInterval = 1.0,
	
	-- Maximum lights to process per frame during recalculation (performance)
	MaxLightsPerFrame = 50,
	
	-- Absolute brightness cap - no light will ever exceed this regardless of original value
	-- Prevents any single light source from blowing out the area on its own
	MaxBrightness = 2.0,
	
	-- Range multiplier applied to all light sources (2.0 = double range)
	RangeMultiplier = 2.0,
	
	-- Smooth transition settings
	TweenDuration = 0.35,         -- How long brightness transitions take (seconds)
	NewLightFadeIn = 0.4,         -- Fade-in time for newly placed lights (seconds)
	TweenEasingStyle = Enum.EasingStyle.Quad,
	TweenEasingDirection = Enum.EasingDirection.Out,
}

-- ============================================
-- STATE
-- ============================================

-- All tracked light data, keyed by light instance
-- { [Light]: { original: number, originalRange: number, block: Instance, buildArea: Instance, position: Vector3, targetBrightness: number, isFlicker: boolean } }
local TrackedLights = {}

-- Active tweens per light (so we can cancel them when a new target comes in)
local ActiveTweens = {} -- { [Light] = Tween }

-- Connections stored per build area for cleanup
local BuildAreaConnections = {}

-- Debounce: which build areas need recalculation
local PendingRecalc = {} -- { [buildArea] = true }
local RecalcScheduled = false

-- Build areas currently in bulk operations (defer recalc)
local DeferredBuildAreas = {} -- { [buildArea] = true }

-- ============================================
-- UTILITY
-- ============================================

local function isLightInstance(instance)
	return instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight")
end

-- Get the world position of a light source (from its parent block/part)
local function getLightWorldPosition(light)
	local parent = light.Parent
	while parent do
		if parent:IsA("BasePart") then
			return parent.Position
		elseif parent:IsA("Model") then
			local primaryPart = parent.PrimaryPart or parent:FindFirstChildWhichIsA("BasePart")
			if primaryPart then
				return primaryPart.Position
			end
		end
		if parent.Name == "Blocks" then
			break
		end
		parent = parent.Parent
	end
	return nil
end

-- Get the block that owns this light (direct child of Blocks folder)
local function getOwnerBlock(light)
	local current = light.Parent
	while current do
		local parent = current.Parent
		if parent and parent.Name == "Blocks" and parent:IsA("Folder") then
			return current
		end
		if parent and string.find(parent.Name or "", GridConfig.BUILD_AREA_PREFIX) then
			break
		end
		current = parent
	end
	return nil
end

-- Get the build area that contains this light
local function getBuildArea(light)
	local current = light.Parent
	while current do
		if string.find(current.Name, GridConfig.BUILD_AREA_PREFIX) then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- Check if a light is currently "active" (enabled)
local function isLightActive(light)
	if not light:IsA("Light") then return false end
	return light.Enabled
end

-- Get the effective range of a light for overlap calculations
local function getLightRange(light)
	if light:IsA("PointLight") or light:IsA("SpotLight") or light:IsA("SurfaceLight") then
		return light.Range
	end
	return 10
end

-- Count total tracked lights in a build area
local function countLightsInArea(buildArea)
	local count = 0
	for _, data in pairs(TrackedLights) do
		if data.buildArea == buildArea then
			count = count + 1
		end
	end
	return count
end

-- ============================================
-- SMOOTH BRIGHTNESS TRANSITIONS
-- ============================================

-- Apply brightness to a light - tweens for normal lights, sets attribute for flicker lights
local function applyBrightness(light, lightData, targetBrightness, duration)
	if not light.Parent then return end
	
	if lightData.isFlicker then
		-- Flicker lights: set attributes and let the FireFlicker script handle visuals
		light:SetAttribute("AdjustedBrightness", targetBrightness)
		
		-- Also scale range proportionally
		local originalRange = lightData.originalRange or getLightRange(light)
		local brightnessFraction = targetBrightness / math.max(lightData.original, 0.01)
		-- Range doesn't need to scale as aggressively as brightness
		local rangeFraction = math.sqrt(brightnessFraction)
		light:SetAttribute("AdjustedRange", originalRange * rangeFraction)
		return
	end
	
	-- Normal lights: smooth tween
	-- Cancel any existing tween on this light
	local existingTween = ActiveTweens[light]
	if existingTween then
		existingTween:Cancel()
		ActiveTweens[light] = nil
	end
	
	-- Skip tween if already at target (within tolerance)
	if math.abs(light.Brightness - targetBrightness) < 0.01 then
		return
	end
	
	local tweenInfo = TweenInfo.new(
		duration or CONFIG.TweenDuration,
		CONFIG.TweenEasingStyle,
		CONFIG.TweenEasingDirection
	)
	
	local tween = TweenService:Create(light, tweenInfo, {
		Brightness = targetBrightness
	})
	
	ActiveTweens[light] = tween
	
	tween.Completed:Connect(function()
		if ActiveTweens[light] == tween then
			ActiveTweens[light] = nil
		end
	end)
	
	tween:Play()
end

-- ============================================
-- CORE: BRIGHTNESS CALCULATION
-- ============================================

-- Calculate distance-weighted overlap count for a light
local function calculateOverlapCount(light, lightData)
	local pos = lightData.position
	if not pos then return 0 end
	
	local range = getLightRange(light)
	local overlapCount = 0
	
	for otherLight, otherData in pairs(TrackedLights) do
		if otherLight ~= light and otherData.buildArea == lightData.buildArea then
			if isLightActive(otherLight) then
				local otherPos = otherData.position
				if otherPos then
					local distance = (pos - otherPos).Magnitude
					local otherRange = getLightRange(otherLight)
					local maxOverlapDist = (range + otherRange) * CONFIG.OverlapThreshold
					
					if distance < maxOverlapDist then
						local weight = 1 - (distance / maxOverlapDist)
						weight = math.clamp(weight, 0, 1)
						overlapCount = overlapCount + weight
					end
				end
			end
		end
	end
	
	return overlapCount
end

-- Calculate adjusted brightness for a light based on nearby overlap
local function calculateAdjustedBrightness(light, lightData)
	local originalBrightness = lightData.original
	if not originalBrightness or originalBrightness <= 0 then
		return 0
	end
	
	-- Cap the original brightness so overly bright lights don't blow out even solo
	local cappedOriginal = math.min(originalBrightness, CONFIG.MaxBrightness)
	
	local overlapCount = calculateOverlapCount(light, lightData)
	
	if overlapCount <= 0 then
		return cappedOriginal
	end
	
	local scaleFactor
	local minBrightness
	
	if overlapCount > CONFIG.DenseClusterThreshold then
		-- Dense cluster: two-stage scaling
		-- Stage 1: normal scaling up to the threshold
		local baseScale = 1 / ((1 + CONFIG.DenseClusterThreshold) ^ CONFIG.ScalePower)
		-- Stage 2: aggressive scaling for the excess overlap beyond threshold
		local excess = overlapCount - CONFIG.DenseClusterThreshold
		local denseScale = 1 / ((1 + excess) ^ CONFIG.DenseClusterPower)
		scaleFactor = baseScale * denseScale
		minBrightness = cappedOriginal * CONFIG.DenseMinBrightnessFraction
	else
		-- Normal spacing: gentle scaling
		scaleFactor = 1 / ((1 + overlapCount) ^ CONFIG.ScalePower)
		minBrightness = cappedOriginal * CONFIG.MinBrightnessFraction
	end
	
	local adjusted = math.max(cappedOriginal * scaleFactor, minBrightness)
	
	return adjusted
end

-- ============================================
-- RECALCULATION
-- ============================================

-- Recalculate all lights in a build area
local function recalcBuildArea(buildArea)
	if BulkOperationFlags.IsBulkOperation(buildArea) then
		DeferredBuildAreas[buildArea] = true
		return
	end
	
	local processedCount = 0
	local adjustedCount = 0
	
	-- First pass: update positions for all lights in this build area
	for light, data in pairs(TrackedLights) do
		if data.buildArea == buildArea and light.Parent then
			data.position = getLightWorldPosition(light)
		end
	end
	
	-- Second pass: calculate and tween to adjusted brightness
	for light, data in pairs(TrackedLights) do
		if data.buildArea == buildArea and light.Parent then
			if isLightActive(light) then
				local adjusted = calculateAdjustedBrightness(light, data)
				
				-- Only apply if the target actually changed
				if not data.targetBrightness or math.abs(data.targetBrightness - adjusted) > 0.01 then
					data.targetBrightness = adjusted
					applyBrightness(light, data, adjusted)
					adjustedCount = adjustedCount + 1
				end
			end
			
			processedCount = processedCount + 1
			if processedCount % CONFIG.MaxLightsPerFrame == 0 then
				task.wait()
			end
		end
	end
	
	if adjustedCount > 0 then
		print(string.format("[LightingManager] Recalculated %d lights (%d adjusted) in %s",
			processedCount, adjustedCount, buildArea.Name))
	end
end

-- Process pending recalculations (debounced)
local function processPendingRecalcs()
	RecalcScheduled = false
	
	local areas = {}
	for buildArea in pairs(PendingRecalc) do
		table.insert(areas, buildArea)
	end
	PendingRecalc = {}
	
	for _, buildArea in ipairs(areas) do
		recalcBuildArea(buildArea)
	end
end

-- Schedule a recalculation for a build area
local function scheduleRecalc(buildArea)
	if not buildArea then return end
	
	PendingRecalc[buildArea] = true
	
	if not RecalcScheduled then
		RecalcScheduled = true
		task.delay(CONFIG.RecalcDebounce, processPendingRecalcs)
	end
end

-- ============================================
-- LIGHT TRACKING
-- ============================================

-- Start tracking a light instance
local function trackLight(light)
	if TrackedLights[light] then return end
	if not isLightInstance(light) then return end
	
	local buildArea = getBuildArea(light)
	if not buildArea then
		print(string.format("[LightingManager] Skipped light '%s' - no build area found", light:GetFullName()))
		return
	end
	
	local block = getOwnerBlock(light)
	local position = getLightWorldPosition(light)
	
	-- Check if this is a flicker light (e.g. campfire)
	local isFlicker = light:GetAttribute("IsFlickerLight") == true
	
	-- For flicker lights, use the FlickerBaseBrightness as the true original
	-- (since the light's current Brightness may be mid-flicker)
	local originalBrightness
	local originalRange = getLightRange(light)
	
	if isFlicker then
		originalBrightness = light:GetAttribute("FlickerBaseBrightness") or light.Brightness
		originalRange = light:GetAttribute("FlickerBaseRange") or originalRange
	else
		originalBrightness = light:GetAttribute("OriginalBrightness")
		if not originalBrightness then
			originalBrightness = light.Brightness
			light:SetAttribute("OriginalBrightness", originalBrightness)
		end
	end
	
	-- Store the true original range before multiplying
	-- If already stored, use that to avoid double-multiplying on re-track
	local storedOriginalRange = light:GetAttribute("OriginalRange")
	if storedOriginalRange then
		originalRange = storedOriginalRange
	else
		light:SetAttribute("OriginalRange", originalRange)
	end
	
	-- Apply range multiplier to extend light reach
	local boostedRange = originalRange * CONFIG.RangeMultiplier
	if isFlicker then
		light:SetAttribute("FlickerBaseRange", boostedRange)
	else
		light.Range = boostedRange
	end
	originalRange = boostedRange
	
	-- Calculate target brightness immediately
	local lightData = {
		original = originalBrightness,
		originalRange = originalRange,
		block = block,
		buildArea = buildArea,
		position = position,
		targetBrightness = nil,
		isFlicker = isFlicker,
	}
	TrackedLights[light] = lightData
	
	local targetBrightness = calculateAdjustedBrightness(light, lightData)
	lightData.targetBrightness = targetBrightness
	
	if isFlicker then
		-- Flicker lights: set attributes immediately, the flicker script reads them
		light:SetAttribute("AdjustedBrightness", targetBrightness)
		local brightnessFraction = targetBrightness / math.max(originalBrightness, 0.01)
		light:SetAttribute("AdjustedRange", originalRange * math.sqrt(brightnessFraction))
	elseif isLightActive(light) then
		-- Normal lights: start at 0 and fade in (no flash)
		light.Brightness = 0
		applyBrightness(light, lightData, targetBrightness, CONFIG.NewLightFadeIn)
	end
	
	local totalInArea = countLightsInArea(buildArea)
	local flickerTag = isFlicker and " [flicker]" or ""
	print(string.format("[LightingManager] Tracking %s%s (original: %.2f, target: %.2f, range: %.0f) in %s [%d total]",
		light.ClassName, flickerTag, originalBrightness, targetBrightness, getLightRange(light),
		buildArea.Name, totalInArea))
	
	-- Listen for Enabled changes (lamp toggling, etc.)
	local enabledConn = light:GetPropertyChangedSignal("Enabled"):Connect(function()
		scheduleRecalc(buildArea)
	end)
	
	-- Clean up when light is destroyed
	local destroyConn
	destroyConn = light.AncestryChanged:Connect(function(_, parent)
		if not parent then
			-- Cancel any active tween
			local activeTween = ActiveTweens[light]
			if activeTween then
				activeTween:Cancel()
				ActiveTweens[light] = nil
			end
			
			TrackedLights[light] = nil
			enabledConn:Disconnect()
			destroyConn:Disconnect()
			local remaining = countLightsInArea(buildArea)
			print(string.format("[LightingManager] Untracked light from %s [%d remaining]", buildArea.Name, remaining))
			scheduleRecalc(buildArea)
		end
	end)
	
	-- Schedule full recalc (will also update neighbors)
	scheduleRecalc(buildArea)
end

-- ============================================
-- BLOCK MONITORING
-- ============================================

local function scanForLights(instance)
	for _, descendant in ipairs(instance:GetDescendants()) do
		if isLightInstance(descendant) then
			trackLight(descendant)
		end
	end
	
	if isLightInstance(instance) then
		trackLight(instance)
	end
end

local function monitorBlock(block)
	scanForLights(block)
	
	block.DescendantAdded:Connect(function(descendant)
		if isLightInstance(descendant) then
			trackLight(descendant)
		end
	end)
end

-- ============================================
-- BUILD AREA MONITORING
-- ============================================

local function monitorBuildArea(buildArea)
	if BuildAreaConnections[buildArea] then return end
	
	local connections = {}
	BuildAreaConnections[buildArea] = connections
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	
	local function setupBlocksFolder(folder)
		local lightCount = 0
		for _, block in ipairs(folder:GetChildren()) do
			if not BulkOperationFlags.IsBulkOperation(buildArea) then
				for _, desc in ipairs(block:GetDescendants()) do
					if isLightInstance(desc) then
						lightCount = lightCount + 1
					end
				end
				monitorBlock(block)
			end
		end
		
		if lightCount > 0 then
			print(string.format("[LightingManager] Found %d existing lights in %s", lightCount, buildArea.Name))
		end
		
		local addedConn = folder.ChildAdded:Connect(function(block)
			task.wait() -- Let the block fully set up
			if BulkOperationFlags.IsBulkOperation(buildArea) then
				DeferredBuildAreas[buildArea] = true
				return
			end
			monitorBlock(block)
		end)
		table.insert(connections, addedConn)
		
		local removedConn = folder.ChildRemoved:Connect(function()
			if not BulkOperationFlags.IsBulkOperation(buildArea) then
				scheduleRecalc(buildArea)
			else
				DeferredBuildAreas[buildArea] = true
			end
		end)
		table.insert(connections, removedConn)
	end
	
	if blocksFolder then
		setupBlocksFolder(blocksFolder)
	end
	
	local childAddedConn = buildArea.ChildAdded:Connect(function(child)
		if child.Name == "Blocks" and child:IsA("Folder") then
			setupBlocksFolder(child)
		end
	end)
	table.insert(connections, childAddedConn)
end

-- ============================================
-- BULK OPERATION HANDLING
-- ============================================

local function checkDeferredAreas()
	for buildArea in pairs(DeferredBuildAreas) do
		if not BulkOperationFlags.IsBulkOperation(buildArea) then
			DeferredBuildAreas[buildArea] = nil
			
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				for _, block in ipairs(blocksFolder:GetChildren()) do
					scanForLights(block)
				end
			end
			
			print(string.format("[LightingManager] Bulk operation ended in %s - rescanning", buildArea.Name))
			scheduleRecalc(buildArea)
		end
	end
end

-- ============================================
-- INITIALIZATION
-- ============================================

local function initialize()
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			monitorBuildArea(buildArea)
		end
	end
	
	workspace.ChildAdded:Connect(function(child)
		if string.find(child.Name, GridConfig.BUILD_AREA_PREFIX) then
			task.wait(0.5)
			monitorBuildArea(child)
		end
	end)
	
	-- Also monitor MegaPlot build area (for private server MegaPlot mode)
	local function setupMegaPlotMonitoring(megaPlotRoom)
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			monitorBuildArea(megaBuildArea)
		end
		megaPlotRoom.ChildAdded:Connect(function(child)
			if child.Name == "MegaPlotBuildArea" then
				task.wait(0.5)
				monitorBuildArea(child)
			end
		end)
	end
	
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		setupMegaPlotMonitoring(megaPlotRoom)
	end
	workspace.ChildAdded:Connect(function(child)
		if child.Name == "MegaPlotRoom" then
			setupMegaPlotMonitoring(child)
		end
	end)
	
	task.spawn(function()
		while true do
			task.wait(CONFIG.BulkCheckInterval)
			checkDeferredAreas()
		end
	end)
end

initialize()

print("[LightingManager] Initialized - monitoring light sources for blowout prevention")
