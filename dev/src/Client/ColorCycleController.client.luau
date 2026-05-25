--[[
	ColorCycleController (Client)
	Animates color-cycling blocks driven by manifest-defined behavior.
	
	Detects blocks with ColorMode = "Rainbow" attribute and animates them per their
	preset's Behavior.ColorCycle config:
	  Behavior = {
	    ColorCycle = {
	      Duration   = 6.0,    -- seconds per full hue cycle
	      Saturation = 0.85,
	      Value      = 1.0,
	      Light      = {       -- optional; presence enables child-light animation
	        Saturation = 1.0,
	        Value      = 1.0,
	      },
	    },
	  }
	
	If a block has no Behavior.ColorCycle (legacy IsRainbow presets), the DEFAULT_CYCLE
	config below is used so existing content keeps working.
	
	Note: Animates ALL plots' rainbow blocks so everyone can see the effect.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))

local player = Players.LocalPlayer

-- ============================================
-- CONFIGURATION
-- ============================================

-- Default cycle config used as fallback when a block has no manifest-defined Behavior.ColorCycle.
-- Matches the original hardcoded rainbow look for backward compat.
local DEFAULT_CYCLE = {
	Duration = 6.0,
	Saturation = 0.85,
	Value = 1.0,
	-- No Light table by default; only blocks whose manifest opts in will have child lights animated
}

-- How often to do a full rescan for new rainbow blocks (seconds)
local SCAN_INTERVAL = 10.0

-- Debug mode
local DEBUG = false

-- ============================================
-- STATE
-- ============================================

-- [block instance] = { parts = {BasePart, ...}, lights = {PointLight, ...}, phase, cycleCfg }
local animatedBlocks = {}
-- [viewport instance] = { parts = {BasePart, ...} }
local rainbowViewports = {}
local lastScanTime = 0
local lastViewportScanTime = 0
local isInitialized = false

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function debugPrint(...)
	if DEBUG then
		print("[ColorCycle]", ...)
	end
end

-- Check if a block has the Rainbow ColorMode attribute
local function isRainbowBlock(block)
	return block:GetAttribute("ColorMode") == "Rainbow"
end

-- Resolve the cycle config for a block by looking up its preset's Behavior.ColorCycle
local function resolveCycleConfig(block)
	local blockType = block:GetAttribute("BlockType")
	if blockType then
		local preset = BlockPresets.GetPreset and BlockPresets.GetPreset(blockType)
		if preset and preset.Behavior and preset.Behavior.ColorCycle then
			return preset.Behavior.ColorCycle
		end
	end
	-- Fallback for legacy rainbow blocks without manifest config
	return DEFAULT_CYCLE
end

-- Collect all animatable parts and lights from a block
local function collectBlockComponents(block)
	local parts = {}
	local lights = {}
	
	if block:IsA("BasePart") then
		table.insert(parts, block)
		for _, child in ipairs(block:GetChildren()) do
			if child:IsA("PointLight") or child:IsA("SpotLight") or child:IsA("SurfaceLight") then
				table.insert(lights, child)
			end
		end
	elseif block:IsA("Model") then
		for _, descendant in ipairs(block:GetDescendants()) do
			if descendant:IsA("BasePart") and descendant.Transparency < 1 then
				table.insert(parts, descendant)
			elseif descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
				table.insert(lights, descendant)
			end
		end
	end
	
	return parts, lights
end

-- Register a single rainbow block for animation
local function registerBlock(block)
	if animatedBlocks[block] then return end -- Already registered
	if not isRainbowBlock(block) then return end
	
	local parts, lights = collectBlockComponents(block)
	
	if #parts == 0 then
		debugPrint("Skipping block with no visible parts:", block:GetFullName())
		return
	end
	
	animatedBlocks[block] = {
		parts = parts,
		lights = lights,
		phase = block:GetAttribute("RainbowPhase") or 0,
		cycleCfg = resolveCycleConfig(block), -- cached so we don't lookup every frame
	}
	
	debugPrint("Registered rainbow block:", block:GetFullName(),
		"| Parts:", #parts, "| Lights:", #lights,
		"| Duration:", animatedBlocks[block].cycleCfg.Duration)
end

-- Unregister a block when it's removed
local function unregisterBlock(block)
	if animatedBlocks[block] then
		animatedBlocks[block] = nil
		debugPrint("Unregistered rainbow block:", block:GetFullName())
	end
end

-- ============================================
-- SCANNING
-- ============================================

local function scanContainer(container)
	for _, child in ipairs(container:GetDescendants()) do
		if (child:IsA("BasePart") or child:IsA("Model")) and isRainbowBlock(child) then
			registerBlock(child)
		end
	end
end

local function watchContainer(container)
	container.DescendantAdded:Connect(function(descendant)
		task.defer(function()
			if descendant and descendant.Parent and isRainbowBlock(descendant) then
				registerBlock(descendant)
			end
		end)
	end)
	
	container.DescendantRemoving:Connect(function(descendant)
		unregisterBlock(descendant)
	end)
end

local function getAllBlocksFolders()
	local blocksFolders = {}
	for _, child in ipairs(workspace:GetChildren()) do
		if string.match(child.Name, "^BuildArea%d+$") then
			local blocksFolder = child:FindFirstChild("Blocks")
			if blocksFolder then
				table.insert(blocksFolders, blocksFolder)
			end
		end
	end
	return blocksFolders
end

local function fullScan()
	local blocksFolders = getAllBlocksFolders()
	if #blocksFolders == 0 then
		debugPrint("No BuildArea Blocks folders found")
		return
	end
	for _, folder in ipairs(blocksFolders) do
		scanContainer(folder)
	end
end

-- ============================================
-- ANIMATION
-- ============================================

local function updateColors(currentTime)
	for block, data in pairs(animatedBlocks) do
		-- Check if block still exists
		if not block or not block.Parent then
			animatedBlocks[block] = nil
			continue
		end
		
		local cfg = data.cycleCfg
		local cycleSpeed = 1.0 / (cfg.Duration or 6.0)
		
		-- Calculate hue based on time + per-block phase offset
		local hue = ((currentTime + data.phase) * cycleSpeed) % 1.0
		
		-- Per-block color from manifest config (no more hardcoded glass desaturation;
		-- if a block needs lower saturation, the manifest declares it).
		local color = Color3.fromHSV(hue, cfg.Saturation or 0.85, cfg.Value or 1.0)
		for _, part in ipairs(data.parts) do
			if part and part.Parent then
				part.Color = color
			end
		end
		
		-- Animate child lights only if the manifest opts in via Behavior.ColorCycle.Light
		if cfg.Light and #data.lights > 0 then
			local lightColor = Color3.fromHSV(hue, cfg.Light.Saturation or 1.0, cfg.Light.Value or 1.0)
			for _, light in ipairs(data.lights) do
				if light and light.Parent then
					light.Color = lightColor
				end
			end
		end
	end
end

-- ============================================
-- INVENTORY VIEWPORT ANIMATION
-- ============================================
-- Inventory ViewportFrames tagged IsRainbow always animate with DEFAULT_CYCLE.
-- (Per-block config would require passing block ID into the viewport; future work.)

local function scanViewports()
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return end
	
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		if descendant:IsA("ViewportFrame") and descendant:GetAttribute("IsRainbow") == true then
			if not rainbowViewports[descendant] then
				local parts = {}
				local worldModel = descendant:FindFirstChild("World")
				if worldModel then
					for _, part in ipairs(worldModel:GetDescendants()) do
						if part:IsA("BasePart") then
							table.insert(parts, part)
						end
					end
				end
				if #parts > 0 then
					rainbowViewports[descendant] = { parts = parts }
				end
			end
		end
	end
end

local function updateViewportColors(currentTime)
	local cycleSpeed = 1.0 / DEFAULT_CYCLE.Duration
	local hue = (currentTime * cycleSpeed) % 1.0
	local color = Color3.fromHSV(hue, DEFAULT_CYCLE.Saturation, DEFAULT_CYCLE.Value)
	
	for viewport, data in pairs(rainbowViewports) do
		if not viewport or not viewport.Parent then
			rainbowViewports[viewport] = nil
			continue
		end
		for _, part in ipairs(data.parts) do
			if part and part.Parent then
				part.Color = color
			end
		end
	end
end

-- ============================================
-- INITIALIZATION
-- ============================================

local function initialize()
	if isInitialized then return end
	isInitialized = true
	
	debugPrint("Initializing ColorCycleController...")
	
	-- Wait briefly for build areas to load
	task.wait(2)
	
	fullScan()
	
	-- Watch existing BuildArea Blocks folders
	for _, child in ipairs(workspace:GetChildren()) do
		if string.match(child.Name, "^BuildArea%d+$") then
			local blocksFolder = child:FindFirstChild("Blocks")
			if blocksFolder then
				watchContainer(blocksFolder)
			end
			child.ChildAdded:Connect(function(newChild)
				if newChild.Name == "Blocks" then
					task.wait(0.5)
					scanContainer(newChild)
					watchContainer(newChild)
				end
			end)
		end
	end
	
	-- Watch for new BuildArea instances
	workspace.ChildAdded:Connect(function(child)
		if string.match(child.Name, "^BuildArea%d+$") then
			task.wait(1)
			local blocksFolder = child:FindFirstChild("Blocks")
			if blocksFolder then
				scanContainer(blocksFolder)
				watchContainer(blocksFolder)
			end
			child.ChildAdded:Connect(function(newChild)
				if newChild.Name == "Blocks" then
					task.wait(0.5)
					scanContainer(newChild)
					watchContainer(newChild)
				end
			end)
		end
	end)
	
	-- Animation loop
	RunService.Heartbeat:Connect(function()
		local currentTime = os.clock()
		
		if currentTime - lastScanTime >= SCAN_INTERVAL then
			lastScanTime = currentTime
			fullScan()
		end
		
		updateColors(currentTime)
		
		if currentTime - lastViewportScanTime >= 2.0 then
			lastViewportScanTime = currentTime
			scanViewports()
		end
		
		updateViewportColors(currentTime)
	end)
	
	debugPrint("ColorCycleController initialized")
end

initialize()
