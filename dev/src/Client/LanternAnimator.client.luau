--[[
	LanternAnimator (Client)
	Handles subtle swinging animation for hanging lanterns
	
	Requirements:
	- Lantern model must have pivot point at TOP (hanging point)
	- Only animates lanterns with IsHanging = true attribute
	
	Animation:
	- Subtle pendulum-like swing using sine waves
	- Random phase offsets so lanterns don't sync
	- Gentle rotation on X and Z axes
	- Uses CFrame multiplication to swing from the pivot point (top of lantern)
	
	Note: Animates ALL plots' lanterns so everyone can see the sway
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer

-- ============================================
-- CONFIGURATION
-- ============================================

local CONFIG = {
	-- Maximum swing angle in degrees (keep subtle - 3-5 degrees looks natural)
	MAX_SWING_ANGLE = 4,
	
	-- Base swing speed (lower = slower, more gentle)
	SWING_SPEED = 0.8,
	
	-- Secondary swing for more natural motion (slight figure-8 pattern)
	SECONDARY_SPEED = 1.3,
	SECONDARY_AMPLITUDE = 0.4, -- Multiplier of main amplitude
	
	-- How often to check for new lanterns (seconds)
	SCAN_INTERVAL = 15.0, -- Reduced frequency since ChildAdded listeners handle most cases
	
	-- Debug mode
	DEBUG = false,
}

-- ============================================
-- STATE
-- ============================================

local animatedLanterns = {} -- [lantern] = { phaseX, phaseZ, speedMult, baseCFrame }
local lastScanTime = 0
local isInitialized = false

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function debugPrint(...)
	if CONFIG.DEBUG then
		print("[LanternAnimator]", ...)
	end
end

-- Check if a block is a hanging lantern
local function isHangingLantern(block)
	if not block then return false end
	return block:GetAttribute("IsLantern") == true and block:GetAttribute("IsHanging") == true
end

-- Get ALL plots' blocks folders in workspace
local function getAllBlocksFolders()
	local blocksFolders = {}
	
	-- Build areas are directly in workspace as BuildArea1, BuildArea2, etc.
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

-- Initialize animation data for a lantern
local function initializeLantern(lantern)
	if animatedLanterns[lantern] then return end
	
	-- Get base CFrame (this is where the lantern should return to)
	local baseCFrame
	if lantern:IsA("Model") then
		baseCFrame = lantern:GetPivot()
	else
		baseCFrame = lantern.CFrame
	end
	
	-- Random phase offsets so lanterns don't swing in sync
	-- This makes each lantern feel unique and natural
	local phaseX = math.random() * math.pi * 2
	local phaseZ = math.random() * math.pi * 2
	
	-- Slight speed variation per lantern (±15%)
	local speedMult = 0.85 + math.random() * 0.3
	
	animatedLanterns[lantern] = {
		phaseX = phaseX,
		phaseZ = phaseZ,
		speedMult = speedMult,
		baseCFrame = baseCFrame,
	}
	
	debugPrint("Initialized hanging lantern:", lantern:GetFullName())
end

-- Remove lantern from animation tracking
local function removeLantern(lantern)
	if animatedLanterns[lantern] then
		animatedLanterns[lantern] = nil
		debugPrint("Removed lantern from animation:", lantern.Name)
	end
end

-- Scan for hanging lanterns in ALL plots' blocks folders
local function scanForLanterns()
	local blocksFolders = getAllBlocksFolders()
	if #blocksFolders == 0 then 
		debugPrint("No blocks folders found - plots not ready yet")
		return 
	end
	
	-- Track which lanterns we found this scan
	local foundLanterns = {}
	local hangingCount = 0
	
	for _, blocksFolder in ipairs(blocksFolders) do
		for _, block in ipairs(blocksFolder:GetChildren()) do
			-- Check if it's a hanging lantern
			if isHangingLantern(block) then
				hangingCount = hangingCount + 1
				foundLanterns[block] = true
				initializeLantern(block)
			end
		end
	end
	
	if CONFIG.DEBUG and hangingCount > 0 then
		debugPrint(string.format("Scan complete: %d hanging lanterns across %d plots", hangingCount, #blocksFolders))
	end
	
	-- Remove any lanterns that no longer exist or are no longer hanging
	for lantern, _ in pairs(animatedLanterns) do
		if not foundLanterns[lantern] or not lantern.Parent then
			removeLantern(lantern)
		end
	end
end

-- ============================================
-- ANIMATION
-- ============================================

local function updateLanternSwing(lantern, data, currentTime)
	if not lantern or not lantern.Parent then
		return false -- Signal to remove
	end
	
	-- Check if it's still a hanging lantern (might have been replaced)
	if not lantern:GetAttribute("IsHanging") then
		return false
	end
	
	local time = currentTime * data.speedMult
	
	-- Primary swing using sine wave - creates pendulum motion
	local swingX = math.sin(time * CONFIG.SWING_SPEED + data.phaseX) * CONFIG.MAX_SWING_ANGLE
	local swingZ = math.sin(time * CONFIG.SWING_SPEED * 0.7 + data.phaseZ) * CONFIG.MAX_SWING_ANGLE
	
	-- Secondary swing adds subtle complexity (slight figure-8 pattern)
	-- This makes the motion feel more natural and less mechanical
	swingX = swingX + math.sin(time * CONFIG.SECONDARY_SPEED + data.phaseX * 1.5) * CONFIG.MAX_SWING_ANGLE * CONFIG.SECONDARY_AMPLITUDE
	swingZ = swingZ + math.cos(time * CONFIG.SECONDARY_SPEED * 0.8 + data.phaseZ * 1.3) * CONFIG.MAX_SWING_ANGLE * CONFIG.SECONDARY_AMPLITUDE
	
	-- Convert to radians
	local rotX = math.rad(swingX)
	local rotZ = math.rad(swingZ)
	
	-- Create swing rotation
	-- Since the pivot is at the TOP of the lantern (hanging point),
	-- rotating around X and Z axes creates a natural pendulum swing
	local swingRotation = CFrame.Angles(rotX, 0, rotZ)
	
	-- Apply swing: start from base position, then apply rotation
	-- The rotation happens around the pivot point (top of lantern)
	local newCFrame = data.baseCFrame * swingRotation
	
	-- Apply to lantern
	if lantern:IsA("Model") then
		lantern:PivotTo(newCFrame)
	else
		lantern.CFrame = newCFrame
	end
	
	return true -- Keep animating
end

-- ============================================
-- MAIN LOOP
-- ============================================

local function onHeartbeat(deltaTime)
	local currentTime = tick()
	
	-- Periodic scan for new lanterns
	if currentTime - lastScanTime > CONFIG.SCAN_INTERVAL then
		lastScanTime = currentTime
		scanForLanterns()
	end
	
	-- Update all animated lanterns
	local toRemove = {}
	
	for lantern, data in pairs(animatedLanterns) do
		local success = updateLanternSwing(lantern, data, currentTime)
		if not success then
			table.insert(toRemove, lantern)
		end
	end
	
	-- Clean up removed lanterns
	for _, lantern in ipairs(toRemove) do
		removeLantern(lantern)
	end
end

-- ============================================
-- EVENT CONNECTIONS
-- ============================================

local blocksFolderConnections = {} -- Store connections for cleanup

local function setupBlocksFolderListener(blocksFolder)
	-- Check if we already have a connection for this folder
	if blocksFolderConnections[blocksFolder] then return end
	
	local connections = {}
	
	-- Listen for new blocks being added
	connections.added = blocksFolder.ChildAdded:Connect(function(child)
		-- Small delay to ensure attributes are set
		task.defer(function()
			if isHangingLantern(child) then
				initializeLantern(child)
			end
		end)
	end)
	
	-- Listen for blocks being removed
	connections.removed = blocksFolder.ChildRemoved:Connect(function(child)
		removeLantern(child)
	end)
	
	blocksFolderConnections[blocksFolder] = connections
	debugPrint("Setup listener for:", blocksFolder:GetFullName())
end

local function setupAllBlocksFolderListeners()
	local blocksFolders = getAllBlocksFolders()
	
	for _, blocksFolder in ipairs(blocksFolders) do
		setupBlocksFolderListener(blocksFolder)
	end
	
	-- Initial scan
	scanForLanterns()
	
	debugPrint("Setup listeners for", #blocksFolders, "blocks folders")
end

-- Watch for new build areas being added
local function watchForNewBuildAreas()
	-- Watch for new BuildArea instances being added to workspace
	workspace.ChildAdded:Connect(function(child)
		if string.match(child.Name, "^BuildArea%d+$") then
			task.delay(0.5, function()
				local blocksFolder = child:FindFirstChild("Blocks")
				if blocksFolder then
					setupBlocksFolderListener(blocksFolder)
					scanForLanterns()
				else
					-- Wait for Blocks folder to be created
					child.ChildAdded:Connect(function(folder)
						if folder.Name == "Blocks" then
							setupBlocksFolderListener(folder)
							scanForLanterns()
						end
					end)
				end
			end)
		end
	end)
	
	-- Also watch for Blocks folder being added to existing build areas
	for _, child in ipairs(workspace:GetChildren()) do
		if string.match(child.Name, "^BuildArea%d+$") then
			child.ChildAdded:Connect(function(folder)
				if folder.Name == "Blocks" then
					setupBlocksFolderListener(folder)
					scanForLanterns()
				end
			end)
		end
	end
end

-- ============================================
-- INITIALIZATION
-- ============================================

local function initialize()
	debugPrint("Initializing LanternAnimator (all plots)...")
	
	-- Wait for character to load
	if not player.Character then
		player.CharacterAdded:Wait()
	end
	
	-- Small delay to ensure plots are loaded
	task.delay(1, function()
		setupAllBlocksFolderListeners()
		watchForNewBuildAreas()
		
		-- Start the animation loop
		RunService.Heartbeat:Connect(onHeartbeat)
		
		debugPrint("LanternAnimator initialized - watching all build areas")
	end)
end

-- Handle player respawning
player.CharacterAdded:Connect(function()
	-- Re-scan for lanterns after respawn
	task.delay(1, function()
		setupAllBlocksFolderListeners()
		scanForLanterns()
	end)
end)

initialize()
